
        <div class="feature-card rounded-xl p-6">
          <div class="flex items-start gap-4">
            <div class="w-12 h-12 rounded-lg bg-green-500/10 flex items-center justify-center flex-shrink-0">
              <span class="text-2xl">🧠</span>
            </div>
            <div>
              <h3 class="text-xl font-semibold text-white mb-2">v0.4.0 — JSON Schema + Agent Context Awareness</h3>
              <p class="text-slate-400 leading-relaxed">
                Two major features shipped:
              </p>
              <ul class="text-slate-400 leading-relaxed mt-2 space-y-1 list-disc list-inside">
                <li><strong>Structured output</strong> — <code>--schema</code> flag constrains model response to a JSON Schema via <code>response_format</code>. No more regex parsing.</li>
                <li><strong>AGENTS.md scanning</strong> — Walk CWD for AGENTS.md files, auto-inject into context.</li>
                <li><strong>Skills autodiscovery</strong> — <code>tau skills list|search|load</code> discovers 113+ skills from <code>~/.agents/skills/</code>.</li>
              </ul>
            </div>
          </div>
        </div>

        <div class="feature-card rounded-xl p-6">
          <div class="flex items-start gap-4">
            <div class="w-12 h-12 rounded-lg bg-blue-500/10 flex items-center justify-center flex-shrink-0">
              <span class="text-2xl">⚡</span>
            </div>
            <div>
              <h3 class="text-xl font-semibold text-white mb-2">Real-time Data Updates</h3>
              <p class="text-slate-400 leading-relaxed">Added WebSocket endpoint for live BTC price and slot updates every second. Replaced REST polling with persistent WebSocket connections for faster, more reliable data.</p>
            </div>
          </div>
        </div>

        <div class="feature-card rounded-xl p-6">
          <div class="flex items-start gap-4">
            <div class="w-12 h-12 rounded-lg bg-emerald-500/10 flex items-center justify-center flex-shrink-0">
              <span class="text-2xl">📊</span>
            </div>
            <div>
              <h3 class="text-xl font-semibold text-white mb-2">Multi-Market Support</h3>
              <p class="text-slate-400 leading-relaxed">Extended data collection to support multiple timeframes (15m, 5m, 1h) simultaneously. Added URL-driven navigation for different market views.</p>
            </div>
          </div>
        </div>

        <div class="feature-card rounded-xl p-6">
          <div class="flex items-start gap-4">
            <div class="w-12 h-12 rounded-lg bg-purple-500/10 flex items-center justify-center flex-shrink-0">
              <span class="text-2xl">💾</span>
            </div>
            <div>
              <h3 class="text-xl font-semibold text-white mb-2">Performance & Storage</h3>
              <p class="text-slate-400 leading-relaxed">Implemented GZip compression and SQLite history storage for faster responses. Added connection pooling to eliminate database overhead.</p>
            </div>
          </div>
        </div>

        <div class="feature-card rounded-xl p-6">
          <div class="flex items-start gap-4">
            <div class="w-12 h-12 rounded-lg bg-amber-500/10 flex items-center justify-center flex-shrink-0">
              <span class="text-2xl">🔍</span>
            </div>
            <div>
              <h3 class="text-xl font-semibold text-white mb-2">Chart Improvements</h3>
              <p class="text-slate-400 leading-relaxed">Added zoom modal with full data support, interval controls, and smart downsampling for smooth performance. Implemented localStorage caching for faster chart loading.</p>
            </div>
          </div>
        </div>

        <div class="feature-card rounded-xl p-6">
          <div class="flex items-start gap-4">
            <div class="w-12 h-12 rounded-lg bg-red-500/10 flex items-center justify-center flex-shrink-0">
              <span class="text-2xl">🐛</span>
            </div>
            <div>
              <h3 class="text-xl font-semibold text-white mb-2">Bug Fixes</h3>
              <p class="text-slate-400 leading-relaxed">Fixed redirect loops, improved data isolation between timeframes, resolved WebSocket connection issues, and added official-beat endpoint support.</p>
            </div>
          </div>
        </div>