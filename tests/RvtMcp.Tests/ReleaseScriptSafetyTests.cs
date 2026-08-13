using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.CompilerServices;
using Xunit;

namespace RvtMcp.Tests
{
    public class ReleaseScriptSafetyTests
    {
        [Fact]
        public void Every_inherited_mutating_entry_point_fails_before_its_implementation()
        {
            var repoRoot = GetRepoRoot();
            var scripts = new Dictionary<string, string>
            {
                ["install.ps1"] = "Cria installer disabled:",
                ["package-client-setup.ps1"] = "Cria packaging disabled:",
                ["stage-plugin-zip.ps1"] = "Cria staging disabled:",
                ["uninstall-all.ps1"] = "Cria uninstaller disabled:",
                ["uninstall-old.ps1"] = "Cria legacy cleanup disabled:"
            };

            foreach (var entry in scripts)
            {
                var text = File.ReadAllText(Path.Combine(repoRoot, "scripts", entry.Key));
                var guardIndex = text.IndexOf("throw '" + entry.Value, StringComparison.Ordinal);
                var implementationIndex = text.IndexOf("$ErrorActionPreference", StringComparison.Ordinal);

                Assert.True(guardIndex >= 0, $"{entry.Key} is missing its Cria fail-fast guard.");
                Assert.True(implementationIndex > guardIndex,
                    $"{entry.Key} can reach inherited implementation setup before its Cria guard.");
            }
        }

        private static string GetRepoRoot([CallerFilePath] string testFile = "")
        {
            return Path.GetFullPath(Path.Combine(Path.GetDirectoryName(testFile)!, "..", ".."));
        }
    }
}
