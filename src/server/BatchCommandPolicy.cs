using System;
using System.Collections.Generic;
using Newtonsoft.Json.Linq;
using RvtMcp.Plugin;

namespace RvtMcp.Server
{
    internal sealed class BatchCommandPolicyViolation
    {
        public BatchCommandPolicyViolation(string code, int index, string command, string message)
        {
            Code = code;
            Index = index;
            Command = command;
            Message = message;
        }

        public string Code { get; }
        public int Index { get; }
        public string Command { get; }
        public string Message { get; }
    }

    internal static class BatchCommandPolicy
    {
        private static readonly HashSet<string> AlwaysBlocked = new HashSet<string>(StringComparer.Ordinal)
        {
            "batch_execute",
            "delete_element",
            "run_baked_tool",
            "send_code_to_revit"
        };

        public static BatchCommandPolicyViolation Validate(
            JArray commands,
            ISet<string> activeMcpToolNames)
        {
            if (commands == null) throw new ArgumentNullException(nameof(commands));
            if (activeMcpToolNames == null) throw new ArgumentNullException(nameof(activeMcpToolNames));

            for (var index = 0; index < commands.Count; index++)
            {
                var command = (commands[index] as JObject)?.Value<string>("command");
                if (string.IsNullOrWhiteSpace(command))
                    continue;

                if (AlwaysBlocked.Contains(command))
                {
                    return new BatchCommandPolicyViolation(
                        "batch_command_forbidden",
                        index,
                        command,
                        $"Command '{command}' cannot run through batch_execute. Use its direct MCP tool under an explicitly enabled profile.");
                }

                if (!AtomicBatchCommandCatalog.IsAllowed(command))
                {
                    return new BatchCommandPolicyViolation(
                        "batch_command_not_atomic",
                        index,
                        command,
                        $"Command '{command}' is not in the audited transaction-only batch allowlist. Call its direct MCP tool separately.");
                }

                var directToolName = "revit_" + command;
                if (!activeMcpToolNames.Contains(directToolName))
                {
                    return new BatchCommandPolicyViolation(
                        "batch_command_not_exposed",
                        index,
                        command,
                        $"Command '{command}' cannot run through batch_execute because '{directToolName}' is not exposed by the active tool profile.");
                }
            }

            return null;
        }
    }
}
