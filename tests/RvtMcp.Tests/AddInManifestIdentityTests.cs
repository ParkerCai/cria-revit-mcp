using System.IO;
using System.Linq;
using System.Runtime.CompilerServices;
using System.Xml.Linq;
using Xunit;

namespace RvtMcp.Tests
{
    public class AddInManifestIdentityTests
    {
        [Fact]
        public void Every_version_uses_the_same_independent_cria_identity()
        {
            var repoRoot = GetRepoRoot();
            var expectedId = "{c34e4573-49c6-4cf7-a820-7b0dbb874a42}";

            foreach (var year in Enumerable.Range(22, 6))
            {
                var path = Path.Combine(
                    repoRoot,
                    "src",
                    $"plugin-r{year}",
                    $"RvtMcp.R{year}.addin");
                var addIn = XDocument.Load(path).Root?.Element("AddIn");

                Assert.NotNull(addIn);
                Assert.Equal("Cria Revit MCP", addIn!.Element("Name")?.Value);
                Assert.Equal(expectedId, addIn.Element("AddInId")?.Value);
                Assert.Equal("CRIA", addIn.Element("VendorId")?.Value);
                Assert.Equal("Cria Revit MCP", addIn.Element("VendorDescription")?.Value);

                // These are deliberate v0.1 compatibility identifiers, not product branding.
                Assert.Equal(@"RvtMcp\RvtMcp.Plugin.dll", addIn.Element("Assembly")?.Value);
                Assert.Equal("RvtMcp.Plugin.App", addIn.Element("FullClassName")?.Value);
            }
        }

        private static string GetRepoRoot([CallerFilePath] string testFile = "")
        {
            return Path.GetFullPath(Path.Combine(Path.GetDirectoryName(testFile)!, "..", ".."));
        }
    }
}
