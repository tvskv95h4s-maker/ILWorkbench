using System.Linq;
// Loads an assembly produced by the patcher and exercises its members through plain reflection.
// This proves that written files are valid IL the runtime accepts, and that edits really took effect.
using System.Reflection;

var path = Path.GetFullPath(args[0]);
var assembly = Assembly.LoadFrom(path);
Console.WriteLine($"loaded {assembly.GetName().Name} from {path}");

var nested = assembly.GetType("SampleLib.Greeter+Nested");
var secret = nested?.GetMethod("Secret", BindingFlags.Public | BindingFlags.Static);
Console.WriteLine($"SampleLib.Greeter+Nested.Secret() => {(secret == null ? "(absent)" : secret.Invoke(null, null))}");

var banner = assembly.GetType("SampleLib.Banner");
var sum = banner?.GetMethod("Sum", BindingFlags.Public | BindingFlags.Static);
Console.WriteLine($"SampleLib.Banner.Sum(1, 2) => {(sum == null ? "(absent)" : sum.Invoke(null, new object[] { 1, 2 }))}");

var render = banner?.GetMethod("Render", BindingFlags.Public | BindingFlags.Static);
Console.WriteLine($"SampleLib.Banner.Render present => {render != null}");

var version = banner?.GetField("Version", BindingFlags.Public | BindingFlags.Static);
if (version == null)
{
    Console.WriteLine("SampleLib.Banner.Version => (absent)");
}
else
{
    version.SetValue(null, 7);
    Console.WriteLine($"SampleLib.Banner.Version round-trip => {version.GetValue(null)}");
}

var added = assembly.GetType("SampleLib.ToolAddedType");
var ping = added?.GetMethod("Ping", BindingFlags.Public | BindingFlags.Static);
Console.WriteLine($"SampleLib.ToolAddedType.Ping() => {(ping == null ? "(absent)" : ping.Invoke(null, null))}");
Console.WriteLine($"SampleLib.Throwaway present => {assembly.GetType("SampleLib.Throwaway") != null}");
Type[] types;
try
{
    types = assembly.GetTypes();
}
catch (ReflectionTypeLoadException ex)
{
    Console.WriteLine("!! type load errors:");
    foreach (var loaderException in ex.LoaderExceptions.Where(e => e != null).Take(5))
        Console.WriteLine("   " + loaderException!.Message);
    types = ex.Types.Where(t => t != null).ToArray()!;
}
Console.WriteLine($"total types => {types.Length}");
