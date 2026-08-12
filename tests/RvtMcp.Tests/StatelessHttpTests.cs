using System;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;
using System.Threading.Tasks;
using Xunit;

namespace RvtMcp.Tests
{
    public class StatelessHttpTests
    {
        [Fact]
        public async Task Modern_discovery_is_sessionless_and_legacy_sse_is_absent()
        {
            var port = ReservePort();
            var tempRoot = Path.Combine(Path.GetTempPath(), "cria-http-test-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(tempRoot);

            using var server = StartServer(port, tempRoot);
            try
            {
                using var client = new HttpClient
                {
                    BaseAddress = new Uri($"http://127.0.0.1:{port}/"),
                    Timeout = TimeSpan.FromSeconds(2)
                };

                var response = await DiscoverWhenReady(client);
                var body = await response.Content.ReadAsStringAsync();

                Assert.Equal(HttpStatusCode.OK, response.StatusCode);
                Assert.False(response.Headers.Contains("Mcp-Session-Id"));

                var dataLine = body.Split('\n')
                    .First(line => line.StartsWith("data: ", StringComparison.Ordinal));
                using var json = JsonDocument.Parse(dataLine.Substring("data: ".Length));
                var result = json.RootElement.GetProperty("result");
                Assert.Equal("complete", result.GetProperty("resultType").GetString());
                Assert.Contains("2026-07-28", result.GetProperty("supportedVersions").ToString());
                Assert.Equal("private", result.GetProperty("cacheScope").GetString());
                Assert.Equal(
                    "cria-revit-mcp",
                    result.GetProperty("_meta")
                        .GetProperty("io.modelcontextprotocol/serverInfo")
                        .GetProperty("name")
                        .GetString());

                using var legacySse = await client.GetAsync("sse");
                Assert.Equal(HttpStatusCode.NotFound, legacySse.StatusCode);
            }
            finally
            {
                if (!server.HasExited)
                {
                    server.Kill(entireProcessTree: true);
                    server.WaitForExit(5_000);
                }

                Directory.Delete(tempRoot, recursive: true);
            }
        }

        private static Process StartServer(int port, string tempRoot)
        {
            var dotnet = Environment.GetEnvironmentVariable("DOTNET_HOST_PATH")
                ?? throw new InvalidOperationException("DOTNET_HOST_PATH is unavailable.");
            var serverAssembly = typeof(RvtMcp.Server.Program).Assembly.Location;
            var startInfo = new ProcessStartInfo
            {
                FileName = dotnet,
                Arguments = $"\"{serverAssembly}\" --http {port} --read-only --disable-toolbaker",
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true
            };
            startInfo.Environment["LOCALAPPDATA"] = tempRoot;
            startInfo.Environment["APPDATA"] = tempRoot;

            return Process.Start(startInfo)
                ?? throw new InvalidOperationException("Failed to start the Cria MCP test server.");
        }

        private static async Task<HttpResponseMessage> DiscoverWhenReady(HttpClient client)
        {
            Exception lastError = null;
            for (var attempt = 0; attempt < 50; attempt++)
            {
                try
                {
                    return await SendDiscover(client);
                }
                catch (HttpRequestException ex)
                {
                    lastError = ex;
                    await Task.Delay(100);
                }
            }

            throw new InvalidOperationException("Cria MCP HTTP server did not become ready.", lastError);
        }

        private static Task<HttpResponseMessage> SendDiscover(HttpClient client)
        {
            const string payload = """
                {
                  "jsonrpc": "2.0",
                  "id": 1,
                  "method": "server/discover",
                  "params": {
                    "_meta": {
                      "io.modelcontextprotocol/protocolVersion": "2026-07-28",
                      "io.modelcontextprotocol/clientInfo": {
                        "name": "cria-tests",
                        "version": "1.0.0"
                      },
                      "io.modelcontextprotocol/clientCapabilities": {}
                    }
                  }
                }
                """;

            var request = new HttpRequestMessage(HttpMethod.Post, "")
            {
                Content = new StringContent(payload, Encoding.UTF8, "application/json")
            };
            request.Headers.Add("MCP-Protocol-Version", "2026-07-28");
            request.Headers.Add("Mcp-Method", "server/discover");
            request.Headers.Accept.ParseAdd("application/json");
            request.Headers.Accept.ParseAdd("text/event-stream");

            return client.SendAsync(request);
        }

        private static int ReservePort()
        {
            var listener = new TcpListener(IPAddress.Loopback, 0);
            listener.Start();
            var port = ((IPEndPoint)listener.LocalEndpoint).Port;
            listener.Stop();
            return port;
        }
    }
}
