using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Net.Http;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace EntraHealthFixtures {
    public sealed class HttpResult {
        public int StatusCode { get; set; }
        public byte[] Bytes { get; set; } = Array.Empty<byte>();
        public string WorkflowRunId { get; set; } = string.Empty;
    }
    public static class BoundedIO {
        private static string ReadRunId(HttpResponseMessage response) {
            if (!response.Headers.TryGetValues("x-ms-workflow-run-id", out var values)) return string.Empty;
            string result = null;
            foreach (var value in values) {
                if (result != null || value.Length == 0 || value.Length > 128 || value.Contains(','))
                    throw new InvalidDataException("Ambiguous workflow run identity.");
                result = value;
            }
            return result ?? string.Empty;
        }
        private static void Kill(Process process) {
            try { if (!process.HasExited) process.Kill(true); } catch { }
        }
        private static async Task<string> ReadBounded(StreamReader reader, int limit, Process process) {
            var text = new StringBuilder();
            var buffer = new char[4096];
            int read;
            while ((read = await reader.ReadAsync(buffer, 0, buffer.Length)) > 0) {
                if (text.Length + read > limit) { Kill(process); throw new InvalidDataException("Worker output bound exceeded."); }
                text.Append(buffer, 0, read);
            }
            return text.ToString();
        }
        private static async Task Feed(Process process, string input, CancellationToken token) {
            await process.StandardInput.WriteAsync(input.AsMemory(), token);
            await process.StandardInput.FlushAsync(token);
            process.StandardInput.Close();
        }
        public static async Task<string> Run(string pwsh, string script, string input, int seconds) {
            if (input.Length > 131072 || seconds < 1 || seconds > 300) throw new InvalidDataException("Invalid worker bound.");
            var start = new ProcessStartInfo(pwsh) {
                UseShellExecute = false, CreateNoWindow = true,
                RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true,
                StandardInputEncoding = new UTF8Encoding(false), StandardOutputEncoding = new UTF8Encoding(false, true),
                StandardErrorEncoding = new UTF8Encoding(false, true)
            };
            foreach (var arg in new[] { "-NoLogo", "-NoProfile", "-NonInteractive", "-File", script }) start.ArgumentList.Add(arg);
            start.Environment["POWERSHELL_TELEMETRY_OPTOUT"] = "1";
            start.Environment["AZURE_CORE_COLLECT_TELEMETRY"] = "false";
            using var process = new Process { StartInfo = start };
            using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(seconds));
            try {
                if (!process.Start()) throw new InvalidOperationException();
                var output = ReadBounded(process.StandardOutput, 2097152, process);
                var error = ReadBounded(process.StandardError, 65536, process);
                var feed = Feed(process, input, deadline.Token);
                await Task.WhenAll(output, error, feed, process.WaitForExitAsync()).WaitAsync(deadline.Token);
                if (process.ExitCode != 0 || error.Result.Length != 0) throw new InvalidOperationException();
                return output.Result;
            } catch {
                Kill(process);
                try { process.WaitForExit(2000); } catch { }
                throw new InvalidOperationException("Validation worker failed or timed out.");
            }
        }
        public static void ValidateJsonObject(string text) {
            using var document = JsonDocument.Parse(text, new JsonDocumentOptions { MaxDepth = 32 });
            if (document.RootElement.ValueKind != JsonValueKind.Object) throw new InvalidDataException("Expected JSON object.");
            CheckUnique(document.RootElement);
        }
        private static void CheckUnique(JsonElement value) {
            if (value.ValueKind == JsonValueKind.Object) {
                var names = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
                foreach (var field in value.EnumerateObject()) {
                    if (!names.Add(field.Name)) throw new InvalidDataException("Duplicate JSON property.");
                    CheckUnique(field.Value);
                }
            } else if (value.ValueKind == JsonValueKind.Array) {
                foreach (var item in value.EnumerateArray()) CheckUnique(item);
            }
        }
        public static async Task<HttpResult> Send(string method, Uri uri, string token, string body, int seconds) {
            using var handler = new HttpClientHandler { AllowAutoRedirect = false, UseCookies = false };
            using var client = new HttpClient(handler) { Timeout = System.Threading.Timeout.InfiniteTimeSpan };
            return await SendCore(client, method, uri, token, body, seconds);
        }
        public static async Task<HttpResult> SendCallback(Uri uri, byte[] body, string contentType, int seconds) {
            using var handler = new HttpClientHandler { AllowAutoRedirect = false, UseCookies = false };
            using var client = new HttpClient(handler) { Timeout = System.Threading.Timeout.InfiniteTimeSpan };
            return await SendCore(client, "POST", uri, null, null, seconds, body, contentType);
        }
        private static async Task<HttpResult> SendCore(HttpClient client, string method, Uri uri, string token, string body, int seconds, byte[] rawBody = null, string contentType = null) {
            if (uri.Scheme != "https" || uri.Port != 443 || uri.UserInfo.Length != 0 || uri.Fragment.Length != 0 || seconds < 1 || seconds > 30)
                throw new InvalidDataException("Invalid HTTP request bound.");
            using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(seconds));
            using var request = new HttpRequestMessage(new HttpMethod(method), uri);
            if (token != null) request.Headers.Authorization = new System.Net.Http.Headers.AuthenticationHeaderValue("Bearer", token);
            request.Headers.TryAddWithoutValidation("Accept", uri.AbsolutePath.EndsWith("/content", StringComparison.Ordinal) ? "text/plain" :
                uri.Host == "management.azure.com" ? "application/json" : "*/*");
            request.Headers.TryAddWithoutValidation("x-ms-version", "2023-11-03");
            request.Headers.TryAddWithoutValidation("x-ms-date", DateTime.UtcNow.ToString("R", System.Globalization.CultureInfo.InvariantCulture));
            if (body != null) request.Content = new StringContent(body, Encoding.UTF8, "application/json");
            if (rawBody != null) {
                if (rawBody.Length > 1048576) throw new InvalidDataException("Request bound exceeded.");
                request.Content = new ByteArrayContent(rawBody);
                request.Content.Headers.ContentType = System.Net.Http.Headers.MediaTypeHeaderValue.Parse(contentType);
            }
            using var response = await client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, deadline.Token);
            if (response.Content.Headers.ContentLength > 1048576) throw new InvalidDataException("Response bound exceeded.");
            using var stream = await response.Content.ReadAsStreamAsync(deadline.Token);
            using var bytes = new MemoryStream();
            var buffer = new byte[8192];
            int read;
            while ((read = await stream.ReadAsync(buffer.AsMemory(), deadline.Token)) > 0) {
                if (bytes.Length + read > 1048576) throw new InvalidDataException("Response bound exceeded.");
                bytes.Write(buffer, 0, read);
            }
            return new HttpResult { StatusCode = (int)response.StatusCode, Bytes = bytes.ToArray(), WorkflowRunId = ReadRunId(response) };
        }
    }
}
