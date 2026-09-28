using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Management;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using Microsoft.Win32.SafeHandles;

// Keystroke driver for tests/snag-console.tests.ps1.
// The test script compiles this and talks to it over stdin. It types into another
// console; it is not the console under test.
internal static class SnagTyper
{
    const int STD_INPUT_HANDLE = -10;
    const int STD_OUTPUT_HANDLE = -11;
    const uint KEY_EVENT = 0x0001;
    const uint SHIFT_PRESSED = 0x0010;
    const uint LEFT_CTRL_PRESSED = 0x0008;
    const uint LEFT_ALT_PRESSED = 0x0002;

    static IntPtr _input;
    static IntPtr _output;
    static StreamWriter _protoOut;
    static StreamReader _protoIn;
    static int _shellPid;
    static int _hostPid;
    static string _shellKind = "ps";
    static string _hostKind = "conhost";
    static string _imageName = "powershell.exe";
    static Process _hostProc;
    static readonly string LogPath = Path.Combine(Path.GetTempPath(), "snag-typer", "typer.log");

    static void Main()
    {
        try
        {
            OpenProtocol();
            Log("typer start sizeof INPUT_RECORD=" + Marshal.SizeOf(typeof(INPUT_RECORD)));
            string line;
            while ((line = _protoIn.ReadLine()) != null)
            {
                line = line.TrimEnd('\r');
                if (line.Length == 0) continue;
                try
                {
                    Handle(line);
                }
                catch (Exception ex)
                {
                    Log("EX " + ex);
                    Reply("ERR " + ex.GetType().Name + ": " + ex.Message);
                }
            }
        }
        catch (Exception ex)
        {
            try { Log("FATAL " + ex); } catch { }
        }
    }

    static void OpenProtocol()
    {
        IntPtr stdin = GetStdHandle(STD_INPUT_HANDLE);
        IntPtr stdout = GetStdHandle(STD_OUTPUT_HANDLE);
        if (stdin == IntPtr.Zero || stdin == new IntPtr(-1) || stdout == IntPtr.Zero || stdout == new IntPtr(-1))
            throw new InvalidOperationException("protocol handles missing in=" + stdin.ToInt64() + " out=" + stdout.ToInt64());
        IntPtr dupIn, dupOut;
        IntPtr self = GetCurrentProcess();
        if (!DuplicateHandle(self, stdin, self, out dupIn, 0, false, 2))
            throw new InvalidOperationException("dup stdin " + Marshal.GetLastWin32Error());
        if (!DuplicateHandle(self, stdout, self, out dupOut, 0, false, 2))
            throw new InvalidOperationException("dup stdout " + Marshal.GetLastWin32Error());
        FreeConsole();
        _protoIn = new StreamReader(new FileStream(new SafeFileHandle(dupIn, true), FileAccess.Read, 4096, false), Encoding.UTF8);
        _protoOut = new StreamWriter(new FileStream(new SafeFileHandle(dupOut, true), FileAccess.Write, 4096, false), new UTF8Encoding(false));
        _protoOut.AutoFlush = true;
    }

    static void Handle(string line)
    {
        Log("<< " + line);
        if (line == "PING") { Reply("OK pong"); return; }
        if (line == "CLOSE") { CloseSession(); Reply("OK closed"); return; }
        if (line == "SCREEN") { Reply("OK " + B64(ReadScreen())); return; }
        if (line == "ROW") { Reply("OK " + B64(ReadCursorRow())); return; }
        if (line == "METRICS") { Reply("OK " + Metrics()); return; }
        if (line.StartsWith("LAUNCH ", StringComparison.Ordinal))
        {
            // LAUNCH conhost|wt ps|cmd <b64 workdir> cols winRows bufRows <b64 exe> <b64 args>
            var parts = SplitN(line, 9);
            string workdir = Encoding.UTF8.GetString(Convert.FromBase64String(parts[3]));
            string exe = Encoding.UTF8.GetString(Convert.FromBase64String(parts[7]));
            string args = Encoding.UTF8.GetString(Convert.FromBase64String(parts[8]));
            Launch(parts[1], parts[2], workdir, short.Parse(parts[4]), short.Parse(parts[5]), short.Parse(parts[6]), exe, args);
            Reply("OK pid=" + _shellPid + " " + Metrics());
            return;
        }
        if (line.StartsWith("LINE ", StringComparison.Ordinal))
        {
            var text = Encoding.UTF8.GetString(Convert.FromBase64String(line.Substring(5).Trim()));
            SendText(text);
            SendEnter();
            Reply("OK sent");
            return;
        }
        if (line.StartsWith("KEYS ", StringComparison.Ordinal))
        {
            var text = Encoding.UTF8.GetString(Convert.FromBase64String(line.Substring(5).Trim()));
            SendText(text);
            Reply("OK keys");
            return;
        }
        if (line == "ENTER") { SendEnter(); Reply("OK enter"); return; }
        if (line.StartsWith("WAIT ", StringComparison.Ordinal))
        {
            // WAIT prompt|text|cont ms [base64]
            var bits = line.Split(new[] { ' ' }, 4);
            var kind = bits[1];
            int ms = int.Parse(bits[2]);
            string needle = "";
            if (bits.Length > 3 && bits[3].Length > 0)
                needle = Encoding.UTF8.GetString(Convert.FromBase64String(bits[3]));
            string err;
            if (WaitFor(kind, needle, ms, out err)) Reply("OK " + B64(Tail()));
            else Reply("ERR timeout " + err + " TAIL " + B64(Tail()));
            return;
        }
        Reply("ERR unknown");
    }

    static string[] SplitN(string line, int n)
    {
        var parts = line.Split(new[] { ' ' }, n);
        if (parts.Length != n) throw new InvalidOperationException("need " + n + " fields: " + line);
        return parts;
    }

    static void Launch(string hostKind, string shellKind, string workdir, short cols, short winRows, short bufRows, string shellExe, string shellArgs)
    {
        CloseSession();
        _hostKind = hostKind;
        _shellKind = shellKind;
        _imageName = Path.GetFileName(shellExe);
        string snap = Path.GetFileNameWithoutExtension(shellExe);
        var before = Snapshot(snap);
        string title = "SNAGTEST-" + shellKind + "-" + hostKind + "-" + Process.GetCurrentProcess().Id;
        string quotedExe = shellExe.IndexOf(' ') >= 0 ? "\"" + shellExe + "\"" : shellExe;

        if (hostKind == "conhost")
        {
            var psi = new ProcessStartInfo();
            psi.FileName = "conhost.exe";
            psi.Arguments = "-- " + quotedExe + " " + shellArgs;
            psi.WorkingDirectory = workdir;
            psi.UseShellExecute = true;
            _hostProc = Process.Start(psi);
            _hostPid = _hostProc.Id;
            Log("started conhost " + _hostPid + " args=" + psi.Arguments);
        }
        else if (hostKind == "wt")
        {
            var psi = new ProcessStartInfo();
            psi.FileName = "wt.exe";
            psi.Arguments = "-w new --size " + cols + "," + winRows + " --title \"" + title + "\" -d \"" + workdir + "\" " + quotedExe + " " + shellArgs;
            psi.UseShellExecute = true;
            psi.WorkingDirectory = workdir;
            _hostProc = Process.Start(psi);
            _hostPid = _hostProc == null ? 0 : _hostProc.Id;
            Log("started wt pid=" + _hostPid + " args=" + psi.Arguments);
        }
        else throw new InvalidOperationException("bad host " + hostKind);

        _shellPid = WaitForShell(shellKind, before, 15000);
        Log("shell pid " + _shellPid);
        if (!AttachWithRetry(_shellPid, 8000))
            throw new InvalidOperationException("AttachConsole failed for " + _shellPid + " err=" + Marshal.GetLastWin32Error());
        try
        {
            BindConsoleHandles();
            SetConsoleTitle(title);
            DisableQuickEdit();
            Resize(cols, winRows, bufRows);
            Log("after resize " + Metrics());
        }
        finally
        {
            Detach();
        }
    }

    static HashSet<int> Snapshot(string name)
    {
        var set = new HashSet<int>();
        foreach (var p in Process.GetProcessesByName(name)) set.Add(p.Id);
        return set;
    }

    static int WaitForShell(string shellKind, HashSet<int> before, int timeoutMs)
    {
        string name = _imageName;
        var sw = Stopwatch.StartNew();
        int found = 0;
        while (sw.ElapsedMilliseconds < timeoutMs)
        {
            foreach (var mo in QueryProcesses())
            {
                int pid = Convert.ToInt32(mo[0]);
                string procName = mo[2] ?? "";
                if (!procName.Equals(name, StringComparison.OrdinalIgnoreCase)) continue;
                if (before.Contains(pid)) continue;
                string cmd = mo[3] ?? "";
                if (shellKind == "ps" && cmd.IndexOf("-NoProfile", StringComparison.OrdinalIgnoreCase) < 0) continue;
                if (shellKind == "cmd" && cmd.IndexOf("/d", StringComparison.OrdinalIgnoreCase) < 0) continue;
                uint parent = Convert.ToUInt32(mo[1]);
                Log("candidate pid=" + pid + " parent=" + parent + " cmd=" + cmd);
                if (_hostKind == "conhost" && parent != (uint)_hostPid)
                {
                    // conhost may re-parent; accept if parent process name is conhost
                    if (!IsPidNamed((int)parent, "conhost.exe") && parent != (uint)_hostPid) continue;
                }
                found = pid;
            }
            if (found != 0) return found;
            Thread.Sleep(150);
        }
        throw new InvalidOperationException("shell did not appear (" + name + ")");
    }

    static bool IsPidNamed(int pid, string name)
    {
        try
        {
            var p = Process.GetProcessById(pid);
            return (p.ProcessName + ".exe").Equals(name, StringComparison.OrdinalIgnoreCase)
                || p.ProcessName.Equals(Path.GetFileNameWithoutExtension(name), StringComparison.OrdinalIgnoreCase);
        }
        catch { return false; }
    }

    static System.Collections.Generic.List<string[]> QueryProcesses()
    {
        var list = new System.Collections.Generic.List<string[]>();
        using (var searcher = new ManagementObjectSearcher("SELECT ProcessId, ParentProcessId, Name, CommandLine FROM Win32_Process"))
        using (var results = searcher.Get())
        {
            foreach (ManagementObject mo in results)
            {
                list.Add(new string[] {
                    Convert.ToString(mo["ProcessId"]),
                    Convert.ToString(mo["ParentProcessId"]),
                    Convert.ToString(mo["Name"]),
                    Convert.ToString(mo["CommandLine"])
                });
            }
        }
        return list;
    }

    static bool AttachWithRetry(int pid, int timeoutMs)
    {
        var sw = Stopwatch.StartNew();
        while (sw.ElapsedMilliseconds < timeoutMs)
        {
            FreeConsole();
            if (AttachConsole((uint)pid)) return true;
            int err = Marshal.GetLastWin32Error();
            Log("attach fail err=" + err);
            Thread.Sleep(150);
        }
        return false;
    }

    static void BindConsoleHandles()
    {
        const uint GENERIC_READ = 0x80000000;
        const uint GENERIC_WRITE = 0x40000000;
        const uint FILE_SHARE_READ = 1;
        const uint FILE_SHARE_WRITE = 2;
        const uint OPEN_EXISTING = 3;
        _input = CreateFileW("CONIN$", GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE, IntPtr.Zero, OPEN_EXISTING, 0, IntPtr.Zero);
        _output = CreateFileW("CONOUT$", GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE, IntPtr.Zero, OPEN_EXISTING, 0, IntPtr.Zero);
        if (_input == IntPtr.Zero || _input == new IntPtr(-1) || _output == IntPtr.Zero || _output == new IntPtr(-1))
            throw new InvalidOperationException("CONIN/CONOUT failed in=" + _input.ToInt64() + " out=" + _output.ToInt64() + " err=" + Marshal.GetLastWin32Error());
    }

    static void Detach()
    {
        if (_input != IntPtr.Zero && _input != new IntPtr(-1)) CloseHandle(_input);
        if (_output != IntPtr.Zero && _output != new IntPtr(-1)) CloseHandle(_output);
        _input = IntPtr.Zero;
        _output = IntPtr.Zero;
        FreeConsole();
    }

    static void WithConsole(Action action)
    {
        if (!AttachWithRetry(_shellPid, 3000))
            throw new InvalidOperationException("reattach failed err=" + Marshal.GetLastWin32Error());
        try
        {
            BindConsoleHandles();
            action();
        }
        finally { Detach(); }
    }

    static void DisableQuickEdit()
    {
        uint mode;
        if (!GetConsoleMode(_input, out mode)) return;
        const uint ENABLE_EXTENDED_FLAGS = 0x0080;
        const uint ENABLE_QUICK_EDIT = 0x0040;
        mode |= ENABLE_EXTENDED_FLAGS;
        mode &= ~ENABLE_QUICK_EDIT;
        SetConsoleMode(_input, mode);
    }

    static void Resize(short cols, short winRows, short bufRows)
    {
        if (bufRows < winRows) bufRows = winRows;
        if (cols < 40) cols = 40;
        CONSOLE_SCREEN_BUFFER_INFO info;
        if (!GetConsoleScreenBufferInfo(_output, out info))
        {
            Log("no buffer info err=" + Marshal.GetLastWin32Error());
            return;
        }
        var win = new SMALL_RECT { Left = 0, Top = 0, Right = (short)(cols - 1), Bottom = (short)(winRows - 1) };
        var big = new COORD { X = cols, Y = bufRows };
        // Grow buffer first when needed so the window fits; shrink window first otherwise.
        bool shrinkW = cols < info.srWindow.Right - info.srWindow.Left + 1 || winRows < info.srWindow.Bottom - info.srWindow.Top + 1;
        bool shrinkB = cols < info.dwSize.X || bufRows < info.dwSize.Y;
        if (shrinkW || shrinkB)
        {
            var smallWin = win;
            if (smallWin.Right >= info.dwSize.X) smallWin.Right = (short)(info.dwSize.X - 1);
            if (smallWin.Bottom >= info.dwSize.Y) smallWin.Bottom = (short)(info.dwSize.Y - 1);
            if (!SetConsoleWindowInfo(_output, true, ref smallWin))
                Log("shrink window err=" + Marshal.GetLastWin32Error());
        }
        if (!SetConsoleScreenBufferSize(_output, big))
            Log("set buffer err=" + Marshal.GetLastWin32Error() + " requested " + cols + "x" + bufRows);
        if (!SetConsoleWindowInfo(_output, true, ref win))
            Log("set window err=" + Marshal.GetLastWin32Error());
    }

    static string Metrics()
    {
        string text = "";
        WithConsole(() =>
        {
            CONSOLE_SCREEN_BUFFER_INFO info;
            if (!GetConsoleScreenBufferInfo(_output, out info)) { text = "nometrics"; return; }
            int winH = info.srWindow.Bottom - info.srWindow.Top + 1;
            int winW = info.srWindow.Right - info.srWindow.Left + 1;
            text = "buf=" + info.dwSize.X + "x" + info.dwSize.Y + " win=" + winW + "x" + winH + " cursor=" + info.dwCursorPosition.X + "," + info.dwCursorPosition.Y;
        });
        return text;
    }

    static void SendText(string text)
    {
        var records = new List<INPUT_RECORD>();
        foreach (char ch in text)
        {
            if (ch == '\r') continue;
            if (ch == '\n') { AddEnter(records); continue; }
            AddChar(records, ch);
        }
        WriteRecords(records);
    }

    static void SendEnter()
    {
        var records = new List<INPUT_RECORD>();
        AddEnter(records);
        WriteRecords(records);
    }

    static void WriteRecords(List<INPUT_RECORD> records)
    {
        if (records.Count == 0) return;
        WithConsole(() =>
        {
            var arr = records.ToArray();
            uint written;
            // Write in chunks so a huge line still lands in order.
            int off = 0;
            while (off < arr.Length)
            {
                int n = Math.Min(32, arr.Length - off);
                var slice = new INPUT_RECORD[n];
                Array.Copy(arr, off, slice, 0, n);
                if (!WriteConsoleInput(_input, slice, (uint)n, out written) || written != (uint)n)
                    throw new InvalidOperationException("WriteConsoleInput wrote " + written + "/" + n + " err=" + Marshal.GetLastWin32Error());
                off += n;
                if (off < arr.Length) Thread.Sleep(5);
            }
        });
    }

    static void AddEnter(List<INPUT_RECORD> records)
    {
        ushort scan = (ushort)MapVirtualKey(0x0D, 0);
        records.Add(MakeKey(0x0D, scan, '\r', 0, true));
        records.Add(MakeKey(0x0D, scan, '\r', 0, false));
    }

    static void AddChar(List<INPUT_RECORD> records, char ch)
    {
        short vkScan = VkKeyScanW(ch);
        if (vkScan == -1)
        {
            records.Add(MakeKey(0, 0, ch, 0, true));
            records.Add(MakeKey(0, 0, ch, 0, false));
            return;
        }
        ushort vk = (ushort)(vkScan & 0xFF);
        byte mods = (byte)((vkScan >> 8) & 0xFF);
        uint control = 0;
        if ((mods & 1) != 0) control |= SHIFT_PRESSED;
        if ((mods & 2) != 0) control |= LEFT_CTRL_PRESSED;
        if ((mods & 4) != 0) control |= LEFT_ALT_PRESSED;
        if ((mods & 1) != 0) records.Add(MakeKey(0x10, (ushort)MapVirtualKey(0x10, 0), '\0', SHIFT_PRESSED, true));
        if ((mods & 2) != 0) records.Add(MakeKey(0x11, (ushort)MapVirtualKey(0x11, 0), '\0', LEFT_CTRL_PRESSED, true));
        if ((mods & 4) != 0) records.Add(MakeKey(0x12, (ushort)MapVirtualKey(0x12, 0), '\0', LEFT_ALT_PRESSED, true));
        ushort scan = (ushort)MapVirtualKey(vk, 0);
        records.Add(MakeKey(vk, scan, ch, control, true));
        records.Add(MakeKey(vk, scan, ch, control, false));
        if ((mods & 4) != 0) records.Add(MakeKey(0x12, (ushort)MapVirtualKey(0x12, 0), '\0', 0, false));
        if ((mods & 2) != 0) records.Add(MakeKey(0x11, (ushort)MapVirtualKey(0x11, 0), '\0', 0, false));
        if ((mods & 1) != 0) records.Add(MakeKey(0x10, (ushort)MapVirtualKey(0x10, 0), '\0', 0, false));
    }

    static INPUT_RECORD MakeKey(ushort vk, ushort scan, char ch, uint control, bool down)
    {
        return new INPUT_RECORD
        {
            EventType = (ushort)KEY_EVENT,
            KeyEvent = new KEY_EVENT_RECORD
            {
                bKeyDown = down ? 1 : 0,
                wRepeatCount = 1,
                wVirtualKeyCode = vk,
                wVirtualScanCode = scan,
                UnicodeChar = ch,
                dwControlKeyState = control
            }
        };
    }

    static bool WaitFor(string kind, string needle, int timeoutMs, out string err)
    {
        err = "";
        var sw = Stopwatch.StartNew();
        int stable = 0;
        int lastX = -2, lastY = -2;
        string lastRow = null;
        while (sw.ElapsedMilliseconds < timeoutMs)
        {
            string row = "";
            int x = 0, y = 0;
            bool attached = true;
            try
            {
                WithConsole(() =>
                {
                    CONSOLE_SCREEN_BUFFER_INFO info;
                    if (!GetConsoleScreenBufferInfo(_output, out info))
                        throw new InvalidOperationException("GetConsoleScreenBufferInfo " + Marshal.GetLastWin32Error());
                    x = info.dwCursorPosition.X;
                    y = info.dwCursorPosition.Y;
                    row = ReadRow(y, info.dwSize.X);
                });
            }
            catch (Exception ex)
            {
                attached = false;
                err = ex.Message;
            }
            if (attached)
            {
                string trim = row.TrimEnd(' ');
                bool ready = false;
                if (kind == "prompt") ready = IsPrompt(trim, row, x);
                else if (kind == "cont") ready = trim == ">>" || trim == "More?";
                else if (kind == "text") ready = trim.IndexOf(needle, StringComparison.Ordinal) >= 0;
                if (ready && x == lastX && y == lastY && row == lastRow) stable++;
                else if (ready) stable = 1;
                else stable = 0;
                lastX = x; lastY = y; lastRow = row;
                if (stable >= 2)
                {
                    err = "row=[" + trim + "] cursor=" + x + "," + y;
                    return true;
                }
            }
            Thread.Sleep(80);
        }
        if (err.Length == 0) err = "row=[" + (lastRow == null ? "" : lastRow.TrimEnd(' ')) + "] cursor=" + lastX + "," + lastY;
        return false;
    }

    static bool IsPrompt(string trim, string raw, int cursorX)
    {
        bool shape;
        if (_shellKind == "cmd")
            shape = Regex.IsMatch(trim, @"^[A-Za-z]:\\.*>$");
        else
            shape = Regex.IsMatch(trim, @"^PS .+>$");
        if (!shape) return false;
        if (cursorX == trim.Length) return true;
        if (cursorX == trim.Length + 1 && cursorX <= raw.Length)
        {
            char gap = raw[trim.Length];
            return gap == ' ';
        }
        return false;
    }

    static string ReadCursorRow()
    {
        string text = "";
        WithConsole(() =>
        {
            CONSOLE_SCREEN_BUFFER_INFO info;
            if (!GetConsoleScreenBufferInfo(_output, out info)) { text = ""; return; }
            text = ReadRow(info.dwCursorPosition.Y, info.dwSize.X).TrimEnd(' ');
        });
        return text;
    }

    static string Tail()
    {
        string screen = ReadScreen();
        var lines = screen.Split('\n');
        var kept = new List<string>();
        for (int i = Math.Max(0, lines.Length - 25); i < lines.Length; i++) kept.Add(lines[i]);
        return string.Join("\n", kept.ToArray());
    }

    static string ReadScreen()
    {
        string text = "";
        WithConsole(() =>
        {
            CONSOLE_SCREEN_BUFFER_INFO info;
            if (!GetConsoleScreenBufferInfo(_output, out info)) { text = ""; return; }
            int width = info.dwSize.X;
            int cursorY = info.dwCursorPosition.Y;
            var sb = new StringBuilder();
            int start = 0;
            // A tall buffer: skip leading blank rows but keep everything up to the cursor.
            for (int y = start; y < cursorY; y++)
            {
                string row = ReadRow(y, width).TrimEnd(' ');
                sb.Append(row);
                sb.Append('\n');
            }
            text = sb.ToString().TrimEnd('\n');
        });
        return text;
    }

    static string ReadRow(int y, int width)
    {
        if (width <= 0) return "";
        var buf = new char[width];
        int read;
        var coord = new COORD { X = 0, Y = (short)y };
        if (!ReadConsoleOutputCharacter(_output, buf, width, coord, out read)) return "";
        return new string(buf, 0, Math.Max(0, Math.Min(read, width)));
    }

    static void CloseSession()
    {
        if (_shellPid == 0) return;
        try
        {
            SendText("exit");
            SendEnter();
            Thread.Sleep(400);
        }
        catch (Exception ex) { Log("exit type failed " + ex.Message); }
        try
        {
            var shell = Process.GetProcessById(_shellPid);
            if (!shell.HasExited) { shell.Kill(); Log("killed shell " + _shellPid); }
        }
        catch { }
        try
        {
            if (_hostKind == "conhost" && _hostProc != null && !_hostProc.HasExited)
            {
                _hostProc.Kill();
                Log("killed conhost " + _hostPid);
            }
        }
        catch { }
        _shellPid = 0;
        _hostPid = 0;
        _hostProc = null;
    }

    static void Reply(string s)
    {
        Log(">> " + (s.Length > 300 ? s.Substring(0, 300) + "..." : s));
        _protoOut.WriteLine(s);
    }

    static void Log(string s)
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(LogPath));
            File.AppendAllText(LogPath, DateTime.Now.ToString("HH:mm:ss.fff ") + s + "\r\n");
        }
        catch { }
    }

    static string B64(string s)
    {
        if (s == null) s = "";
        return Convert.ToBase64String(Encoding.UTF8.GetBytes(s));
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern IntPtr GetCurrentProcess();
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool DuplicateHandle(IntPtr srcProc, IntPtr src, IntPtr dstProc, out IntPtr target, uint access, bool inherit, uint options);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool AttachConsole(uint dwProcessId);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool FreeConsole();
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern IntPtr GetStdHandle(int nStdHandle);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool CloseHandle(IntPtr handle);
    [DllImport("kernel32.dll", EntryPoint = "CreateFileW", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern IntPtr CreateFileW(string name, uint access, uint share, IntPtr sec, uint disp, uint flags, IntPtr template);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool GetConsoleMode(IntPtr h, out uint mode);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool SetConsoleMode(IntPtr h, uint mode);
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool SetConsoleTitle(string title);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool GetConsoleScreenBufferInfo(IntPtr h, out CONSOLE_SCREEN_BUFFER_INFO info);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool SetConsoleScreenBufferSize(IntPtr h, COORD size);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool SetConsoleWindowInfo(IntPtr h, bool absolute, ref SMALL_RECT rect);
    [DllImport("kernel32.dll", EntryPoint = "ReadConsoleOutputCharacterW", SetLastError = true, CharSet = CharSet.Unicode, ExactSpelling = true)]
    static extern bool ReadConsoleOutputCharacter(IntPtr h, [Out] char[] buf, int len, COORD coord, out int read);
    [DllImport("kernel32.dll", EntryPoint = "WriteConsoleInputW", SetLastError = true, CharSet = CharSet.Unicode, ExactSpelling = true)]
    static extern bool WriteConsoleInput(IntPtr h, INPUT_RECORD[] buffer, uint length, out uint written);
    [DllImport("user32.dll")]
    static extern short VkKeyScanW(char ch);
    [DllImport("user32.dll")]
    static extern uint MapVirtualKey(uint code, uint mapType);

    [StructLayout(LayoutKind.Sequential)]
    struct COORD { public short X; public short Y; }
    [StructLayout(LayoutKind.Sequential)]
    struct SMALL_RECT { public short Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)]
    struct CONSOLE_SCREEN_BUFFER_INFO
    {
        public COORD dwSize;
        public COORD dwCursorPosition;
        public short wAttributes;
        public SMALL_RECT srWindow;
        public COORD dwMaximumWindowSize;
    }
    [StructLayout(LayoutKind.Explicit, Size = 16)]
    struct KEY_EVENT_RECORD
    {
        [FieldOffset(0)] public int bKeyDown;
        [FieldOffset(4)] public ushort wRepeatCount;
        [FieldOffset(6)] public ushort wVirtualKeyCode;
        [FieldOffset(8)] public ushort wVirtualScanCode;
        [FieldOffset(10)] public char UnicodeChar;
        [FieldOffset(12)] public uint dwControlKeyState;
    }
    [StructLayout(LayoutKind.Explicit, Size = 20)]
    struct INPUT_RECORD
    {
        [FieldOffset(0)] public ushort EventType;
        [FieldOffset(4)] public KEY_EVENT_RECORD KeyEvent;
    }
}
