using System;
using System.Collections.Generic;

namespace RvtMcp.Plugin
{
    internal static class AtomicBatchCommandCatalog
    {
        private static readonly HashSet<string> Allowed =
            new HashSet<string>(new[]
            {
                "assign_elements_to_workset",
                "change_element_type",
                "color_elements",
                "create_grid",
                "create_group_from_elements",
                "create_level",
                "create_line_based_element",
                "create_point_based_element",
                "create_room",
                "create_schedule",
                "create_sheet",
                "create_surface_based_element",
                "create_view",
                "place_schedule_on_sheet",
                "place_view_on_sheet",
                "set_element_parameter_values",
                "set_type_parameter_values"
            }, StringComparer.Ordinal);

        public static bool IsAllowed(string commandName)
        {
            return commandName != null && Allowed.Contains(commandName);
        }
    }
}
