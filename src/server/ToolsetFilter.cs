using System;
using System.Collections.Generic;
using System.Linq;
using RvtMcp.Plugin;

namespace RvtMcp.Server
{
    /// <summary>
    /// A3 toolset resolver (aspect #3 §A3). Resolves <see cref="RvtMcpConfig.Toolsets"/>
    /// to a concrete set of enabled toolset names, applying defaults + the <c>"all"</c>
    /// shortcut + the <c>--read-only</c> shortcut.
    /// </summary>
    public static class ToolsetFilter
    {
        public static readonly string[] KnownToolsets =
        {
            "query", "create", "modify", "delete", "view",
            "export", "annotation", "mep", "schedule", "families", "graphics", "toolbaker", "meta", "lint",
            "sheets", "materials", "geometry", "rooms", "links", "parameters", "organization", "workflows",
            "structural", "kei"
        };

        public static readonly string[] DefaultOn =
        {
            "query", "create", "modify", "view", "schedule", "families", "mep", "graphics", "export", "meta", "lint",
            "sheets", "materials", "geometry", "annotation", "rooms", "links", "parameters", "organization", "workflows",
            "structural", "kei"
        };

        public static readonly string[] WriteCapable =
        {
            "create", "modify", "delete", "schedule", "families", "mep", "graphics", "export", "toolbaker",
            "sheets", "materials", "annotation", "rooms", "links", "parameters", "organization", "workflows",
            "structural", "kei"
        };

        public static HashSet<string> Resolve(RvtMcpConfig config)
        {
            var requested = config?.Toolsets;
            var usingDefaults = requested == null || requested.Count == 0;
            HashSet<string> set;

            if (usingDefaults)
            {
                set = new HashSet<string>(DefaultOn, StringComparer.OrdinalIgnoreCase);
            }
            else if (requested.Any(t => string.Equals(t, "all", StringComparison.OrdinalIgnoreCase)))
            {
                set = new HashSet<string>(KnownToolsets, StringComparer.OrdinalIgnoreCase);
            }
            else
            {
                set = new HashSet<string>(requested, StringComparer.OrdinalIgnoreCase);
            }

            // Drop unknown tokens silently (misspelling shouldn't crash the server)
            set.IntersectWith(KnownToolsets);

            // Developer mode adds the arbitrary-C# ToolBaker surface to the default
            // catalog. Explicit --toolsets still wins and is never expanded here.
            if (usingDefaults && config?.EnableToolbakerOrDefault == true)
                set.Add("toolbaker");

            // --read-only shortcut: strip every write-capable toolset regardless of
            // whether it was requested explicitly, via "all", or via defaults.
            if (config != null && config.ReadOnlyOrDefault)
            {
                foreach (var w in WriteCapable) set.Remove(w);
            }

            // An explicit toolset list (including "all") is an intentional override.
            // Only an explicit disable removes ToolBaker from that requested surface.
            if ((usingDefaults && config?.EnableToolbakerOrDefault != true)
                || config?.EnableToolbaker == false)
                set.Remove("toolbaker");

            return set;
        }
    }
}
