using System;
using System.Diagnostics;
using System.IO;
using System.Text.Json;
using System.Threading.Tasks;
using Xunit;

namespace RvtMcp.Tests
{
    public class StdioProtocolTests
    {
        [Fact]
        public async Task Modern_discovery_works_over_stdio_without_initialize()
        {
            var tempRoot = Path.Combine(Path.GetTempPath(), "cria-stdio-test-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(tempRoot);

            using var server = StartServer(tempRoot);
            try
            {
                const string request = """
                    {"jsonrpc":"2.0","id":1,"method":"server/discover","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientInfo":{"name":"cria-tests","version":"1.0.0"},"io.modelcontextprotocol/clientCapabilities":{}}}}
                    """;

                await server.StandardInput.WriteLineAsync(request);
                await server.StandardInput.FlushAsync();

                var responseLine = await server.StandardOutput.ReadLineAsync().WaitAsync(TimeSpan.FromSeconds(5));
                Assert.False(string.IsNullOrWhiteSpace(responseLine));

                using var json = JsonDocument.Parse(responseLine);
                var result = json.RootElement.GetProperty("result");
                Assert.Equal("complete", result.GetProperty("resultType").GetString());
                Assert.Contains("2026-07-28", result.GetProperty("supportedVersions").ToString());
                Assert.Equal(
                    "cria-revit-mcp",
                    result.GetProperty("_meta")
                        .GetProperty("io.modelcontextprotocol/serverInfo")
                        .GetProperty("name")
                        .GetString());
            }
            finally
            {
                server.StandardInput.Close();
                if (!server.WaitForExit(5_000))
                {
                    server.Kill(entireProcessTree: true);
                    server.WaitForExit(5_000);
                }

                Directory.Delete(tempRoot, recursive: true);
            }
        }

        private static Process StartServer(string tempRoot)
        {
            var dotnet = Environment.GetEnvironmentVariable("DOTNET_HOST_PATH")
                ?? throw new InvalidOperationException("DOTNET_HOST_PATH is unavailable.");
            var serverAssembly = typeof(RvtMcp.Server.Program).Assembly.Location;
            var startInfo = new ProcessStartInfo
            {
                FileName = dotnet,
                Arguments = $"\"{serverAssembly}\" --profile read-only --disable-toolbaker",
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardInput = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true
            };
            ClearInheritedCriaConfiguration(startInfo);
            startInfo.Environment["LOCALAPPDATA"] = tempRoot;
            startInfo.Environment["APPDATA"] = tempRoot;

            return Process.Start(startInfo)
                ?? throw new InvalidOperationException("Failed to start the Cria MCP stdio test server.");
        }

        private static void ClearInheritedCriaConfiguration(ProcessStartInfo startInfo)
        {
            foreach (var name in new[]
            {
                "CRIA_PROFILE",
                "BIMWRIGHT_TARGET",
                "BIMWRIGHT_TOOLSETS",
                "BIMWRIGHT_READ_ONLY",
                "BIMWRIGHT_ALLOW_LAN_BIND",
                "BIMWRIGHT_ENABLE_TOOLBAKER",
                "BIMWRIGHT_ENABLE_ADAPTIVE_BAKE",
                "BIMWRIGHT_CACHE_SEND_CODE_BODIES",
                "BIMWRIGHT_ENABLE_TOAST",
                "BIMWRIGHT_PERSIST_SEND_CODE_BODIES",
                "BIMWRIGHT_PERSIST_SEND_CODE_BODIES_TTL"
            })
            {
                startInfo.Environment.Remove(name);
            }
        }
    }
}
