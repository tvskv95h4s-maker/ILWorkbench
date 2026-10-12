using System.Text;

namespace SampleLib
{
    public enum Severity
    {
        Low = 1,
        Medium = 2,
        High = 3
    }

    public interface IReporter
    {
        void Report(string message);
        Severity MaxSeverity { get; }
    }

    public class Greeter : IReporter
    {
        private const string DefaultPrefix = "Hello, ";
        private const int DefaultLimit = 3;
        private int _count;

        public event EventHandler<string>? Greeted;

        public Severity MaxSeverity => Severity.Medium;

        public string Prefix { get; set; } = DefaultPrefix;

        public int Count => _count;

        public Greeter()
        {
        }

        public Greeter(string prefix)
        {
            Prefix = prefix;
        }

        public string Greet(string name, int times = 1)
        {
            var builder = new StringBuilder();
            for (var i = 0; i < times; i++)
            {
                builder.Append(Prefix).Append(name).Append('!');
                _count++;
                Greeted?.Invoke(this, builder.ToString());
            }
            return builder.ToString();
        }

        public bool IsOverLimit()
        {
            return _count > DefaultLimit;
        }

        public void Report(string message)
        {
            Console.WriteLine("[report] " + message);
        }

        public static int Add(int a, int b) => a + b;

        public class Nested
        {
            public static string Secret() => "nested-secret-42";
        }
    }

    public static class Banner
    {
        public static string Render(string title)
        {
            return "=== " + title + " ===";
        }
    }
}
