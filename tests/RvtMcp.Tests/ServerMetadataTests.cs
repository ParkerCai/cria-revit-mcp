using ModelContextProtocol.Server;
using Xunit;

namespace RvtMcp.Tests
{
    public class ServerMetadataTests
    {
        [Fact]
        public void Server_identifies_as_cria()
        {
            var options = new McpServerOptions();

            RvtMcp.Server.Program.ConfigureMcpServerOptions(options);

            Assert.Equal("cria-revit-mcp", options.ServerInfo?.Name);
            Assert.Equal("Cria Revit MCP", options.ServerInfo?.Title);
            Assert.Equal("0.1.0", options.ServerInfo?.Version);
            Assert.Contains("stateless", options.ServerInfo?.Description);
            Assert.Equal("https://github.com/ParkerCai/cria-revit-mcp", options.ServerInfo?.WebsiteUrl);
            Assert.StartsWith("cria-revit-mcp", options.ServerInstructions);
        }
    }
}
