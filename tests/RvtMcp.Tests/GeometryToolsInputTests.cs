using System;
using System.Linq;
using System.Text.Json;
using Newtonsoft.Json;
using Newtonsoft.Json.Linq;
using RvtMcp.Server;
using Xunit;

namespace RvtMcp.Tests
{
    public class GeometryToolsInputTests
    {
        [Fact]
        public void Find_elements_volume_normalizes_nested_json_element_for_plugin_payload()
        {
            using var document = JsonDocument.Parse(
                @"{""min"":{""x"":-2000,""y"":-2000,""z"":-16000000},""max"":{""x"":8000,""y"":6000,""z"":16000000}}");

            var normalized = GeometryTools.NormalizeFindElementsVolume(document.RootElement);
            var payload = JObject.Parse(JsonConvert.SerializeObject(new { volume = normalized }));

            Assert.Equal(JTokenType.Object, payload["volume"]?.Type);
            Assert.Equal(-2000, payload.SelectToken("volume.min.x")?.Value<double>());
            Assert.Equal(-16000000, payload.SelectToken("volume.min.z")?.Value<double>());
            Assert.Equal(8000, payload.SelectToken("volume.max.x")?.Value<double>());
            Assert.Equal(16000000, payload.SelectToken("volume.max.z")?.Value<double>());
        }

        [Fact]
        public void Find_elements_volume_rejects_non_object_json_element()
        {
            using var document = JsonDocument.Parse(@"[1,2,3]");

            var exception = Assert.Throws<ArgumentException>(() =>
                GeometryTools.NormalizeFindElementsVolume(document.RootElement));

            Assert.Equal("volume must be a JSON object when supplied.", exception.Message);
        }

        [Fact]
        public void Find_elements_volume_preserves_null_for_room_mode()
        {
            Assert.Null(GeometryTools.NormalizeFindElementsVolume(null));
        }

        [Fact]
        public void Find_elements_volume_keeps_object_parameter_contract()
        {
            var parameter = typeof(GeometryTools)
                .GetMethod(nameof(GeometryTools.FindElementsInVolume))!
                .GetParameters()
                .Single(candidate => candidate.Name == "volume");

            Assert.Equal(typeof(object), parameter.ParameterType);
        }
    }
}
