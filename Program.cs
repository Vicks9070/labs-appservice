using Microsoft.EntityFrameworkCore;
using BrezyWeather.Data;
using Serilog;
using Serilog.Events;
using Serilog.Sinks.Datadog.Logs;

// Bootstrap logger for startup errors (before host is built)
Log.Logger = new LoggerConfiguration()
    .MinimumLevel.Information()
    .WriteTo.Console()
    .CreateBootstrapLogger();

try
{
    var builder = WebApplication.CreateBuilder(args);

    // Configure Serilog from appsettings + environment
    builder.Host.UseSerilog((context, services, loggerConfig) =>
    {
        var ddApiKey = context.Configuration["Datadog:ApiKey"]
                       ?? Environment.GetEnvironmentVariable("DD_API_KEY")
                       ?? "";
        var ddSite = context.Configuration["Datadog:Site"] ?? "datadoghq.com";
        var ddService = context.Configuration["Datadog:Service"] ?? "brezyweather";
        var ddEnv = context.Configuration["Datadog:Env"]
                    ?? Environment.GetEnvironmentVariable("DD_ENV")
                    ?? "development";
        var ddVersion = context.Configuration["Datadog:Version"]
                        ?? Environment.GetEnvironmentVariable("DD_VERSION")
                        ?? "0.0.0";

        loggerConfig
            .MinimumLevel.Information()
            .MinimumLevel.Override("Microsoft.AspNetCore", LogEventLevel.Warning)
            .MinimumLevel.Override("Microsoft.EntityFrameworkCore", LogEventLevel.Warning)
            .Enrich.FromLogContext()
            .Enrich.WithMachineName()
            .Enrich.WithThreadId()
            .Enrich.WithProperty("service", ddService)
            .Enrich.WithProperty("env", ddEnv)
            .Enrich.WithProperty("version", ddVersion)
            // Console sink -- always active, structured JSON in production
            .WriteTo.Console(
                outputTemplate: context.HostingEnvironment.IsDevelopment()
                    ? "[{Timestamp:HH:mm:ss} {Level:u3}] {Message:lj}{NewLine}{Exception}"
                    : null,
                formatter: context.HostingEnvironment.IsDevelopment()
                    ? null
                    : new Serilog.Formatting.Json.JsonFormatter()
            );

        // Datadog sink -- only active when API key is provided
        if (!string.IsNullOrEmpty(ddApiKey))
        {
            var ddConfig = new DatadogConfiguration(url: $"https://http-intake.logs.{ddSite}");
            loggerConfig.WriteTo.DatadogLogs(
                apiKey: ddApiKey,
                source: "csharp",
                service: ddService,
                host: Environment.MachineName,
                tags: new[] { $"env:{ddEnv}", $"version:{ddVersion}" },
                configuration: ddConfig
            );
        }
    });

    // Add services to the container.
    builder.Services.AddRazorPages();
    builder.Services.AddDbContext<WeatherContext>(options => options.UseInMemoryDatabase("WeatherDb"));

    var app = builder.Build();

    // Serilog request logging -- replaces default Microsoft request logs
    app.UseSerilogRequestLogging(options =>
    {
        options.EnrichDiagnosticContext = (diagnosticContext, httpContext) =>
        {
            diagnosticContext.Set("RequestHost", httpContext.Request.Host.Value);
            diagnosticContext.Set("UserAgent", httpContext.Request.Headers["User-Agent"].ToString());
        };
        // Exclude noisy paths from request logs
        options.GetLevel = (httpContext, elapsed, ex) =>
        {
            var path = httpContext.Request.Path.Value ?? "";
            if (path.StartsWith("/health") || path.StartsWith("/lib/") || path.EndsWith(".ico"))
                return LogEventLevel.Verbose; // effectively suppressed
            if (ex != null || httpContext.Response.StatusCode >= 500)
                return LogEventLevel.Error;
            if (elapsed > 5000 || httpContext.Response.StatusCode >= 400)
                return LogEventLevel.Warning;
            return LogEventLevel.Information;
        };
    });

    // Configure the HTTP request pipeline.
    if (!app.Environment.IsDevelopment())
    {
        app.UseExceptionHandler("/Error");
    }
    app.UseStaticFiles();

    app.UseRouting();

    app.UseAuthorization();

    app.MapRazorPages();

    Log.Information("BrezyWeather application starting");
    app.Run();
}
catch (Exception ex)
{
    Log.Fatal(ex, "Application terminated unexpectedly");
}
finally
{
    Log.CloseAndFlush();
}
