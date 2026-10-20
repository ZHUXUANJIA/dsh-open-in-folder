// DSHOpenInFolder.cs
// 「在 DeepSeek Harness 中打开」Windows 资源管理器右键菜单启动器。
//
// 协议见项目 CONTRACT.md「launcher exe 契约」：
//   1. 解析文件夹参数并规范化（Path.GetFullPath，去掉末尾 “\”，盘符根保留）；
//   2. 定位 state 目录：--state-dir → 环境变量 DSH_OPEN_IN_FOLDER_STATE_DIR → DSH_HOME\open-in-folder
//      （DSH_HOME 环境变量，缺省 %USERPROFILE%\.dsh）；
//   3. 读 state.json 并 GET /dsh-open-in-folder/health；若不存在或不健康，则启动 DSH 桌面应用，
//      然后每 500ms 轮询 health，最长 timeout 秒（默认 90）；
//   4. POST /dsh-open-in-folder/request（X-DSH-Open-In-Folder-Token 请求头 + UTF-8 JSON body）；
//      连接失败时每 600ms 重试，最长 timeout 秒；HTTP 4xx 立即失败并展示服务端 error 文本；
//   5. 成功后：若 DSH 在本次启动前已在运行且未指定 --no-activate，则再启动一次 DSH 以触发单实例聚焦；
//   6. 成功完全静默、退出码 0；失败弹中文 MessageBox 并退出码 1；文件夹参数非法退出码 2。
//
// 本文件必须保存为 UTF-8 带 BOM，且只使用 C# 5 语法（.NET Framework 4.8 的 csc.exe）：
//   csc.exe /nologo /target:winexe /codepage:65001 /out:DSHOpenInFolder.exe ^
//     /r:System.Windows.Forms.dll /r:System.Drawing.dll DSHOpenInFolder.cs
//
// 测试专用扩展参数（正常右键菜单调用不会传，不影响契约行为）：
//   --timeout <秒>   覆盖 health 等待 / POST 重试的超时时间（默认 90）
//   --no-dialog      完全抑制 MessageBox（测试用；也可用环境变量 DSH_OPEN_IN_FOLDER_NO_DIALOG=1）
//
// 命令行：
//   DSHOpenInFolder.exe "<folder>" [--no-activate] [--state-dir <dir>] [--app <dsh-exe>]
//                       [--timeout <sec>] [--no-dialog]

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Net;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Windows.Forms;
using Microsoft.Win32;

namespace DshOpenInFolder
{
    internal static class Program
    {
        private const string DialogTitle = "DeepSeek Harness";
        private const string UserAgent = "DSHOpenInFolder/1.0";
        private const int DefaultTimeoutSeconds = 90;
        private const int HealthPollIntervalMs = 500;
        private const int RequestRetryIntervalMs = 600;
        private const int HttpConnectTimeoutMs = 5000;
        private const int HealthTimeoutMs = 2500;
        private const int MaxLogBytes = 512 * 1024;

        private static bool s_SuppressDialogs;

        [STAThread]
        private static int Main(string[] args)
        {
            s_SuppressDialogs = HasNoDialogArg(args)
                || IsTruthy(Environment.GetEnvironmentVariable("DSH_OPEN_IN_FOLDER_NO_DIALOG"));
            try
            {
                return Run(args);
            }
            catch (Exception ex)
            {
                return Fail(null, "启动器发生未预期的错误：\r\n" + ex.Message, 1);
            }
        }

        private static int Run(string[] args)
        {
            string folderArg, stateDirFlag, appFlag;
            bool noActivate, noDialog;
            int timeoutSeconds;
            string parseError = ParseArgs(args, out folderArg, out stateDirFlag, out appFlag,
                out noActivate, out noDialog, out timeoutSeconds);
            if (noDialog)
            {
                s_SuppressDialogs = true;
            }
            if (parseError != null)
            {
                return Fail(null, parseError, 2);
            }
            if (string.IsNullOrEmpty(folderArg))
            {
                return Fail(null,
                    "缺少必需参数：要打开的文件夹路径。\r\n\r\n"
                    + "用法：DSHOpenInFolder.exe \"<folder>\" [--no-activate] [--state-dir <dir>] [--app <dsh-exe>]",
                    2);
            }

            // 1) 规范化并校验文件夹。
            string normalizeError;
            string folder = NormalizeFolder(folderArg, out normalizeError);
            if (folder == null)
            {
                return Fail(null, normalizeError, 2);
            }

            // 2) 定位 state 目录。
            string stateDir;
            try
            {
                stateDir = ResolveStateDir(stateDirFlag);
            }
            catch (Exception ex)
            {
                return Fail(null, "无法确定 DSH 状态目录：\r\n" + ex.Message, 1);
            }

            TryLog(stateDir, "info", "open-folder request: " + folder);

            // 3) 读取 state.json + health 探测。
            string host;
            int port;
            string token;
            bool wasRunning = TryReadState(stateDir, out host, out port, out token) && CheckHealth(host, port);
            string appExe = null;

            if (!wasRunning)
            {
                appExe = ResolveAppExe(appFlag, stateDir);
                if (string.IsNullOrEmpty(appExe))
                {
                    return Fail(stateDir,
                        "未能找到 DeepSeek Harness 应用程序（DeepSeek Harness.exe）。\r\n\r\n"
                        + "已尝试：--app 参数、环境变量 DSH_APP_EXE、app-path.txt、\r\n"
                        + "注册表 HKCU\\Software\\Classes\\dsh\\shell\\open\\command。\r\n\r\n"
                        + "请安装 DSH 桌面版，或运行 install.ps1 指定正确的应用路径。",
                        1);
                }

                string startError;
                if (!StartDsh(appExe, out startError))
                {
                    return Fail(stateDir, startError, 1);
                }
                TryLog(stateDir, "info", "started DSH: " + appExe);

                if (!WaitForHost(stateDir, timeoutSeconds, out host, out port, out token))
                {
                    return Fail(stateDir,
                        string.Format(CultureInfo.CurrentCulture,
                            "DeepSeek Harness 已启动，但「右键打开」插件在 {0} 秒内未就绪。\r\n\r\n"
                            + "可能原因：\r\n"
                            + "1. 尚未安装或未加载 dsh-open-in-folder 插件（请运行 install.ps1）；\r\n"
                            + "2. DSH 仍在启动中或启动失败。\r\n\r\n"
                            + "建议：完全退出 DSH 后重新打开，再重试此操作。",
                            timeoutSeconds),
                        1);
                }
                TryLog(stateDir, "info", string.Format(CultureInfo.InvariantCulture, "plugin ready: {0}:{1}", host, port));
            }
            else
            {
                TryLog(stateDir, "info", string.Format(CultureInfo.InvariantCulture, "DSH already running: {0}:{1}", host, port));
            }

            // 4) POST /dsh-open-in-folder/request（失败重试）。
            string postError;
            int postResult = PostRequest(host, port, token, folder, timeoutSeconds, out postError);
            if (postResult != 0)
            {
                return Fail(stateDir, postError, 1);
            }
            TryLog(stateDir, "info", "request accepted");

            // 5) 若 DSH 在本次点击前已在运行，再启动一次以触发单实例聚焦。
            if (!noActivate && wasRunning)
            {
                string focusApp = appExe;
                if (string.IsNullOrEmpty(focusApp))
                {
                    focusApp = ResolveAppExe(appFlag, stateDir);
                }
                if (!string.IsNullOrEmpty(focusApp))
                {
                    string ignored;
                    if (StartDsh(focusApp, out ignored))
                    {
                        TryLog(stateDir, "info", "focus request sent: " + focusApp);
                    }
                }
                else
                {
                    TryLog(stateDir, "warn", "focus skipped: DSH app exe not found");
                }
            }

            // 6) 成功：完全静默。
            return 0;
        }

        // ------------------------------------------------------------------
        // 参数解析
        // ------------------------------------------------------------------

        private static string ParseArgs(string[] args, out string folder, out string stateDirFlag,
            out string appFlag, out bool noActivate, out bool noDialog, out int timeoutSeconds)
        {
            folder = null;
            stateDirFlag = null;
            appFlag = null;
            noActivate = false;
            noDialog = false;
            timeoutSeconds = DefaultTimeoutSeconds;
            if (args == null || args.Length == 0)
            {
                return null;
            }

            for (int i = 0; i < args.Length; i++)
            {
                string raw = args[i];
                if (raw == null)
                {
                    continue;
                }
                string arg = raw.Trim();
                if (arg.Length == 0)
                {
                    continue;
                }

                string name = arg;
                string inlineValue = null;
                int eq = arg.IndexOf('=');
                if (arg.StartsWith("--", StringComparison.Ordinal) && eq > 2)
                {
                    name = arg.Substring(0, eq);
                    inlineValue = arg.Substring(eq + 1);
                }

                if (name == "--no-activate")
                {
                    noActivate = true;
                    continue;
                }
                if (name == "--no-dialog")
                {
                    noDialog = true;
                    continue;
                }
                if (name == "--state-dir" || name == "--app" || name == "--timeout")
                {
                    string value = inlineValue;
                    if (value == null)
                    {
                        if (i + 1 >= args.Length || args[i + 1] == null)
                        {
                            return "参数 " + name + " 缺少取值。";
                        }
                        i++;
                        value = args[i];
                    }
                    value = TrimQuotes((value ?? "").Trim());
                    if (value.Length == 0)
                    {
                        return "参数 " + name + " 的取值为空。";
                    }
                    if (name == "--state-dir")
                    {
                        stateDirFlag = value;
                    }
                    else if (name == "--app")
                    {
                        appFlag = value;
                    }
                    else
                    {
                        int parsed;
                        if (!int.TryParse(value, NumberStyles.Integer, CultureInfo.InvariantCulture, out parsed)
                            || parsed <= 0 || parsed > 600)
                        {
                            return "参数 --timeout 需要一个 1 到 600 之间的整数秒数，收到：" + value;
                        }
                        timeoutSeconds = parsed;
                    }
                    continue;
                }
                if (name.StartsWith("--", StringComparison.Ordinal))
                {
                    return "无法识别的参数：" + name + "\r\n\r\n"
                        + "用法：DSHOpenInFolder.exe \"<folder>\" [--no-activate] [--state-dir <dir>] [--app <dsh-exe>]";
                }

                // 第一个非选项参数视为文件夹。
                if (folder == null)
                {
                    folder = TrimQuotes(arg);
                }
            }

            if (folder != null && folder.Length == 0)
            {
                folder = null;
            }
            return null;
        }

        private static string TrimQuotes(string value)
        {
            if (value == null)
            {
                return null;
            }
            string result = value.Trim();
            if (result.Length >= 2 && result[0] == '"' && result[result.Length - 1] == '"')
            {
                result = result.Substring(1, result.Length - 2).Trim();
            }
            return result;
        }

        private static bool HasNoDialogArg(string[] args)
        {
            if (args == null)
            {
                return false;
            }
            for (int i = 0; i < args.Length; i++)
            {
                if (args[i] != null && args[i].Trim() == "--no-dialog")
                {
                    return true;
                }
            }
            return false;
        }

        // ------------------------------------------------------------------
        // 路径处理
        // ------------------------------------------------------------------

        private static string NormalizeFolder(string raw, out string error)
        {
            error = null;
            string value = TrimQuotes(raw);
            if (string.IsNullOrEmpty(value))
            {
                error = "文件夹路径为空。";
                return null;
            }
            if (!Path.IsPathRooted(value))
            {
                error = "文件夹路径必须是绝对路径，收到：" + value;
                return null;
            }

            string full;
            try
            {
                full = Path.GetFullPath(value);
            }
            catch (Exception ex)
            {
                error = "无法解析文件夹路径：" + value + "\r\n" + ex.Message;
                return null;
            }

            // 去掉末尾目录分隔符；盘符根（C:\）保留。
            while (full.Length > 3 && (full.EndsWith("\\", StringComparison.Ordinal) || full.EndsWith("/", StringComparison.Ordinal)))
            {
                full = full.Substring(0, full.Length - 1);
            }

            if (!Directory.Exists(full))
            {
                error = "文件夹不存在或不是目录：\r\n" + full;
                return null;
            }
            return full;
        }

        private static string ResolveStateDir(string flag)
        {
            string value = flag;
            if (IsBlank(value))
            {
                value = Environment.GetEnvironmentVariable("DSH_OPEN_IN_FOLDER_STATE_DIR");
            }
            if (!IsBlank(value))
            {
                string expanded = Environment.ExpandEnvironmentVariables(TrimQuotes(value.Trim()));
                return Path.GetFullPath(expanded);
            }

            string home = Environment.GetEnvironmentVariable("DSH_HOME");
            if (!IsBlank(home))
            {
                string expandedHome = Environment.ExpandEnvironmentVariables(TrimQuotes(home.Trim()));
                return Path.Combine(Path.GetFullPath(expandedHome), "open-in-folder");
            }

            string userProfile = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
            if (IsBlank(userProfile))
            {
                throw new InvalidOperationException("无法确定用户目录（USERPROFILE 为空），请设置 DSH_HOME 环境变量后重试。");
            }
            return Path.Combine(userProfile, ".dsh", "open-in-folder");
        }

        private static string ResolveAppExe(string appFlag, string stateDir)
        {
            List<string> candidates = new List<string>();
            AddCandidate(candidates, appFlag);
            AddCandidate(candidates, Environment.GetEnvironmentVariable("DSH_APP_EXE"));
            if (!IsBlank(stateDir))
            {
                AddCandidate(candidates, ReadFirstLine(Path.Combine(stateDir, "app-path.txt")));
            }
            AddCandidate(candidates, ReadRegistryAppExe());

            for (int i = 0; i < candidates.Count; i++)
            {
                string candidate = candidates[i];
                try
                {
                    if (!IsBlank(candidate) && File.Exists(candidate))
                    {
                        return Path.GetFullPath(candidate);
                    }
                }
                catch
                {
                    // 忽略无效候选路径。
                }
            }
            return null;
        }

        private static void AddCandidate(List<string> candidates, string value)
        {
            if (IsBlank(value))
            {
                return;
            }
            string candidate;
            try
            {
                candidate = Environment.ExpandEnvironmentVariables(TrimQuotes(value.Trim()));
            }
            catch
            {
                return;
            }
            if (!IsBlank(candidate))
            {
                candidates.Add(candidate);
            }
        }

        private static string ReadFirstLine(string path)
        {
            try
            {
                if (IsBlank(path) || !File.Exists(path))
                {
                    return null;
                }
                string[] lines = File.ReadAllLines(path, Encoding.UTF8);
                for (int i = 0; i < lines.Length; i++)
                {
                    string line = (lines[i] ?? "").Trim();
                    if (line.Length > 0)
                    {
                        return Environment.ExpandEnvironmentVariables(line);
                    }
                }
            }
            catch
            {
                // 忽略读取失败，继续其他候选。
            }
            return null;
        }

        private static string ReadRegistryAppExe()
        {
            try
            {
                using (RegistryKey key = Registry.CurrentUser.OpenSubKey(
                    @"Software\Classes\dsh\shell\open\command", false))
                {
                    if (key == null)
                    {
                        return null;
                    }
                    string command = key.GetValue(null) as string;
                    return ParseCommandExecutable(command);
                }
            }
            catch
            {
                return null;
            }
        }

        private static string ParseCommandExecutable(string command)
        {
            if (IsBlank(command))
            {
                return null;
            }
            string text = command.Trim();
            string exe = null;
            if (text[0] == '"')
            {
                int end = text.IndexOf('"', 1);
                if (end > 1)
                {
                    exe = text.Substring(1, end - 1);
                }
            }
            else
            {
                int space = text.IndexOf(' ');
                exe = space > 0 ? text.Substring(0, space) : text;
            }
            if (IsBlank(exe))
            {
                return null;
            }
            exe = exe.Trim().Trim('"');
            return exe.Length > 0 ? Environment.ExpandEnvironmentVariables(exe) : null;
        }

        // ------------------------------------------------------------------
        // state.json / health
        // ------------------------------------------------------------------

        private static bool TryReadState(string stateDir, out string host, out int port, out string token)
        {
            host = null;
            port = 0;
            token = null;
            if (IsBlank(stateDir))
            {
                return false;
            }
            string statePath = Path.Combine(stateDir, "state.json");
            string text;
            try
            {
                if (!File.Exists(statePath))
                {
                    return false;
                }
                text = File.ReadAllText(statePath, Encoding.UTF8);
            }
            catch
            {
                return false;
            }

            Match portMatch = Regex.Match(text, "\"port\"\\s*:\\s*(\\d+)");
            Match tokenMatch = Regex.Match(text, "\"token\"\\s*:\\s*\"([^\"]+)\"");
            if (!portMatch.Success || !tokenMatch.Success)
            {
                return false;
            }

            int parsedPort;
            if (!int.TryParse(portMatch.Groups[1].Value, NumberStyles.Integer, CultureInfo.InvariantCulture, out parsedPort)
                || parsedPort <= 0 || parsedPort > 65535)
            {
                return false;
            }

            string parsedHost = "127.0.0.1";
            Match hostMatch = Regex.Match(text, "\"host\"\\s*:\\s*\"([^\"]+)\"");
            if (hostMatch.Success && !IsBlank(hostMatch.Groups[1].Value))
            {
                parsedHost = hostMatch.Groups[1].Value;
            }

            host = parsedHost;
            port = parsedPort;
            token = tokenMatch.Groups[1].Value;
            return true;
        }

        private static bool CheckHealth(string host, int port)
        {
            string url = BuildUrl(host, port, "/dsh-open-in-folder/health");
            try
            {
                HttpWebRequest request = (HttpWebRequest)WebRequest.Create(url);
                request.Method = "GET";
                request.Proxy = null;
                request.Timeout = HealthTimeoutMs;
                request.ReadWriteTimeout = HealthTimeoutMs;
                request.KeepAlive = false;
                request.AllowAutoRedirect = false;
                request.UserAgent = UserAgent;
                using (HttpWebResponse response = (HttpWebResponse)request.GetResponse())
                {
                    if ((int)response.StatusCode != 200)
                    {
                        return false;
                    }
                    string body = ReadResponseText(response);
                    return Regex.IsMatch(body, "\"ok\"\\s*:\\s*true");
                }
            }
            catch
            {
                return false;
            }
        }

        private static bool WaitForHost(string stateDir, int timeoutSeconds, out string host, out int port, out string token)
        {
            host = null;
            port = 0;
            token = null;
            DateTime deadline = DateTime.UtcNow.AddSeconds(timeoutSeconds);
            while (true)
            {
                string candidateHost;
                int candidatePort;
                string candidateToken;
                if (TryReadState(stateDir, out candidateHost, out candidatePort, out candidateToken)
                    && CheckHealth(candidateHost, candidatePort))
                {
                    host = candidateHost;
                    port = candidatePort;
                    token = candidateToken;
                    return true;
                }
                if (DateTime.UtcNow >= deadline)
                {
                    return false;
                }
                Thread.Sleep(HealthPollIntervalMs);
            }
        }

        // ------------------------------------------------------------------
        // POST /dsh-open-in-folder/request
        // ------------------------------------------------------------------

        private static int PostRequest(string host, int port, string token, string folder,
            int timeoutSeconds, out string error)
        {
            error = null;
            DateTime deadline = DateTime.UtcNow.AddSeconds(timeoutSeconds);
            string lastError = null;
            bool nonRetryable = false;

            while (true)
            {
                bool retryable;
                string attemptError;
                int result = PostRequestOnce(host, port, token, folder, out attemptError, out retryable);
                if (result == 0)
                {
                    return 0;
                }
                lastError = attemptError;
                if (!retryable)
                {
                    nonRetryable = true;
                    break;
                }
                if (DateTime.UtcNow >= deadline)
                {
                    break;
                }
                Thread.Sleep(RequestRetryIntervalMs);
            }

            if (nonRetryable)
            {
                error = lastError;
            }
            else
            {
                error = string.Format(CultureInfo.CurrentCulture,
                    "已尝试 {0} 秒仍无法把请求发送给 DeepSeek Harness（{1}:{2}）。\r\n\r\n最后一次错误：\r\n{3}",
                    timeoutSeconds, host, port, lastError);
            }
            return 1;
        }

        private static int PostRequestOnce(string host, int port, string token, string folder,
            out string error, out bool retryable)
        {
            error = null;
            retryable = true;
            string url = BuildUrl(host, port, "/dsh-open-in-folder/request");

            HttpWebRequest request;
            try
            {
                request = (HttpWebRequest)WebRequest.Create(url);
            }
            catch (Exception ex)
            {
                error = "无法创建 HTTP 请求：" + ex.Message;
                return 1;
            }

            request.Method = "POST";
            request.Proxy = null;
            request.Timeout = HttpConnectTimeoutMs;
            request.ReadWriteTimeout = HttpConnectTimeoutMs;
            request.KeepAlive = false;
            request.AllowAutoRedirect = false;
            request.UserAgent = UserAgent;
            request.ContentType = "application/json; charset=utf-8";
            request.Headers["X-DSH-Open-In-Folder-Token"] = token;

            byte[] body = Encoding.UTF8.GetBytes("{\"path\":" + JsonQuote(folder) + "}");
            request.ContentLength = body.Length;

            try
            {
                using (Stream stream = request.GetRequestStream())
                {
                    stream.Write(body, 0, body.Length);
                }
                using (HttpWebResponse response = (HttpWebResponse)request.GetResponse())
                {
                    string responseText = ReadResponseText(response);
                    int status = (int)response.StatusCode;
                    if (status == 200)
                    {
                        TryLog(null, "info", "POST /request -> 200 " + Truncate(responseText, 300));
                        return 0;
                    }
                    error = FormatHttpError(status, responseText);
                    retryable = !(status >= 400 && status < 500);
                    return 1;
                }
            }
            catch (WebException webEx)
            {
                HttpWebResponse errorResponse = webEx.Response as HttpWebResponse;
                if (errorResponse != null)
                {
                    using (errorResponse)
                    {
                        int status = (int)errorResponse.StatusCode;
                        string responseText = ReadResponseText(errorResponse);
                        error = FormatHttpError(status, responseText);
                        retryable = !(status >= 400 && status < 500);
                        return 1;
                    }
                }
                error = string.Format(CultureInfo.InvariantCulture,
                    "无法连接 DeepSeek Harness（{0}:{1}）：{2}", host, port, webEx.Message);
                retryable = true;
                return 1;
            }
            catch (Exception ex)
            {
                error = "发送请求失败：" + ex.Message;
                retryable = true;
                return 1;
            }
        }

        private static string FormatHttpError(int status, string responseText)
        {
            string serverMessage = ExtractJsonStringField(responseText, "error");
            string serverHint = "";
            if (status == 400)
            {
                serverHint = "\r\n\r\n提示：请确认 DSH 已加载最新插件；若 DSH 刚刚重启过，请直接重试。";
            }
            if (!IsBlank(serverMessage))
            {
                return string.Format(CultureInfo.CurrentCulture,
                    "DeepSeek Harness 拒绝了打开请求（HTTP {0}）：\r\n{1}{2}", status, serverMessage, serverHint);
            }
            return string.Format(CultureInfo.CurrentCulture,
                "DeepSeek Harness 拒绝了打开请求（HTTP {0}）。\r\n服务端响应：{1}{2}",
                status, Truncate(responseText, 500), serverHint);
        }

        private static string ExtractJsonStringField(string json, string fieldName)
        {
            if (IsBlank(json) || IsBlank(fieldName))
            {
                return null;
            }
            string pattern = "\"" + Regex.Escape(fieldName) + "\"\\s*:\\s*\"((?:[^\"\\\\]|\\\\.)*)\"";
            Match match = Regex.Match(json, pattern);
            if (!match.Success)
            {
                return null;
            }
            return JsonUnescape(match.Groups[1].Value);
        }

        private static string JsonUnescape(string value)
        {
            if (IsBlank(value))
            {
                return "";
            }
            StringBuilder builder = new StringBuilder(value.Length);
            for (int i = 0; i < value.Length; i++)
            {
                char c = value[i];
                if (c != '\\' || i + 1 >= value.Length)
                {
                    builder.Append(c);
                    continue;
                }
                i++;
                char esc = value[i];
                switch (esc)
                {
                    case 'n': builder.Append('\n'); break;
                    case 'r': builder.Append('\r'); break;
                    case 't': builder.Append('\t'); break;
                    case 'b': builder.Append('\b'); break;
                    case 'f': builder.Append('\f'); break;
                    case '"': builder.Append('"'); break;
                    case '\\': builder.Append('\\'); break;
                    case '/': builder.Append('/'); break;
                    case 'u':
                        if (i + 4 < value.Length)
                        {
                            int code;
                            if (int.TryParse(value.Substring(i + 1, 4), NumberStyles.HexNumber,
                                CultureInfo.InvariantCulture, out code))
                            {
                                builder.Append((char)code);
                                i += 4;
                            }
                            else
                            {
                                builder.Append("\\u");
                            }
                        }
                        else
                        {
                            builder.Append("\\u");
                        }
                        break;
                    default:
                        builder.Append(esc);
                        break;
                }
            }
            return builder.ToString();
        }

        private static string BuildUrl(string host, int port, string path)
        {
            string safeHost = IsBlank(host) ? "127.0.0.1" : host.Trim();
            return "http://" + safeHost + ":" + port.ToString(CultureInfo.InvariantCulture) + path;
        }

        private static string ReadResponseText(HttpWebResponse response)
        {
            if (response == null)
            {
                return "";
            }
            try
            {
                Stream stream = response.GetResponseStream();
                if (stream == null)
                {
                    return "";
                }
                using (StreamReader reader = new StreamReader(stream, Encoding.UTF8))
                {
                    return reader.ReadToEnd();
                }
            }
            catch
            {
                return "";
            }
        }

        // ------------------------------------------------------------------
        // 启动 DSH / 通用工具
        // ------------------------------------------------------------------

        private static bool StartDsh(string exePath, out string error)
        {
            error = null;
            try
            {
                ProcessStartInfo startInfo = new ProcessStartInfo(exePath);
                startInfo.UseShellExecute = true;
                string workingDirectory = Path.GetDirectoryName(exePath);
                if (!IsBlank(workingDirectory))
                {
                    startInfo.WorkingDirectory = workingDirectory;
                }
                Process.Start(startInfo);
                return true;
            }
            catch (Exception ex)
            {
                error = "启动 DeepSeek Harness 失败：\r\n" + exePath + "\r\n" + ex.Message;
                return false;
            }
        }

        private static int Fail(string stateDir, string message, int exitCode)
        {
            TryLog(stateDir, "error", message);
            if (!s_SuppressDialogs)
            {
                try
                {
                    MessageBox.Show(message, DialogTitle, MessageBoxButtons.OK, MessageBoxIcon.Error);
                }
                catch
                {
                    // MessageBox 失败时仍返回退出码。
                }
            }
            return exitCode;
        }

        private static void TryLog(string stateDir, string level, string message)
        {
            try
            {
                if (IsBlank(stateDir))
                {
                    return;
                }
                string directory = stateDir;
                if (!Directory.Exists(directory))
                {
                    string parent = Path.GetDirectoryName(directory);
                    if (IsBlank(parent) || !Directory.Exists(parent))
                    {
                        return;
                    }
                    Directory.CreateDirectory(directory);
                }
                string logPath = Path.Combine(directory, "launcher.log");
                try
                {
                    FileInfo info = new FileInfo(logPath);
                    if (info.Exists && info.Length > MaxLogBytes)
                    {
                        info.Delete();
                    }
                }
                catch
                {
                    // 日志轮转失败不影响主流程。
                }
                string line = string.Format(CultureInfo.InvariantCulture,
                    "{0}\t{1}\t{2}\r\n",
                    DateTime.Now.ToString("yyyy-MM-dd'T'HH:mm:ss.fffzzz", CultureInfo.InvariantCulture),
                    level,
                    (message ?? "").Replace("\r", "\\r").Replace("\n", "\\n"));
                File.AppendAllText(logPath, line, new UTF8Encoding(false));
            }
            catch
            {
                // 日志只是排障辅助，任何失败都必须静默。
            }
        }

        private static string JsonQuote(string value)
        {
            if (value == null)
            {
                return "\"\"";
            }
            StringBuilder builder = new StringBuilder(value.Length + 16);
            builder.Append('"');
            for (int i = 0; i < value.Length; i++)
            {
                char c = value[i];
                switch (c)
                {
                    case '"': builder.Append("\\\""); break;
                    case '\\': builder.Append("\\\\"); break;
                    case '\b': builder.Append("\\b"); break;
                    case '\f': builder.Append("\\f"); break;
                    case '\n': builder.Append("\\n"); break;
                    case '\r': builder.Append("\\r"); break;
                    case '\t': builder.Append("\\t"); break;
                    default:
                        if (c < ' ' || c == '\u007f')
                        {
                            builder.Append("\\u");
                            builder.Append(((int)c).ToString("x4", CultureInfo.InvariantCulture));
                        }
                        else
                        {
                            builder.Append(c);
                        }
                        break;
                }
            }
            builder.Append('"');
            return builder.ToString();
        }

        private static string Truncate(string value, int maxLength)
        {
            if (IsBlank(value))
            {
                return "";
            }
            string text = value.Trim();
            if (text.Length <= maxLength)
            {
                return text;
            }
            return text.Substring(0, maxLength) + "…";
        }

        private static bool IsBlank(string value)
        {
            return value == null || value.Trim().Length == 0;
        }

        private static bool IsTruthy(string value)
        {
            if (IsBlank(value))
            {
                return false;
            }
            string text = value.Trim();
            return text == "1"
                || string.Equals(text, "true", StringComparison.OrdinalIgnoreCase)
                || string.Equals(text, "yes", StringComparison.OrdinalIgnoreCase)
                || string.Equals(text, "on", StringComparison.OrdinalIgnoreCase);
        }
    }
}
