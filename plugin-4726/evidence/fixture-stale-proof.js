defineProvider({
  id: "fixture-stale-proof",
  name: "Fixture Usage",
  topLevel: true,
  endpoints: [{ setting: "BASE_URL", policy: "https-or-loopback-http" }],
  settings: [{ key: "BASE_URL", title: "Base URL", type: "plain" }],
  capabilities: ["http-status"],
  async fetchUsage(ctx) {
    const base = (ctx.settings.get("BASE_URL") || "http://127.0.0.1:8765").replace(/\/+$/u, "");
    const response = await ctx.http.get(base + "/usage");
    if (response.status !== 200) {
      throw ctx.fail.apiFailure(
        "Usage request failed (HTTP " + response.status + "): fixture endpoint stopped responding.",
      );
    }
    const payload = JSON.parse(response.bodyText);
    return { primary: { usedPercent: payload.used, windowMinutes: 300 } };
  },
});
