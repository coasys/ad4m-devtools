import { useState } from 'preact/hooks';
import { JsonViewer } from './JsonViewer';

interface Props {
  perspectiveUUID: string;
}

export function SparqlEditor({ perspectiveUUID }: Props) {
  const [query, setQuery] = useState('SELECT ?s ?p ?o WHERE { ?s ?p ?o } LIMIT 20');
  const [lang, setLang] = useState<'sparql' | 'prolog'>('sparql');
  const [result, setResult] = useState<any>(null);
  const [error, setError] = useState<string | null>(null);
  const [running, setRunning] = useState(false);

  const run = () => {
    setRunning(true);
    setError(null);
    setResult(null);
    // Base64-encode the query to avoid all string-escaping issues
    const queryB64 = btoa(unescape(encodeURIComponent(query)));
    const method = lang === 'sparql' ? 'runSparqlQuery' : 'runQuery';
    const expr = `
      (async () => {
        const dt = window.__AD4M_DEVTOOLS__;
        if (!dt?.${method}) return JSON.stringify({ error: 'No ${method} available — bridge may need updating' });
        try {
          const q = decodeURIComponent(escape(atob('${queryB64}')));
          const r = await dt.${method}('${perspectiveUUID}', q);
          return JSON.stringify({ data: r });
        } catch(e) {
          return JSON.stringify({ error: e.message || String(e) });
        }
      })()
    `;
    if (typeof chrome !== 'undefined' && chrome.devtools?.inspectedWindow) {
      chrome.devtools.inspectedWindow.eval(expr, (res: any, err: any) => {
        setRunning(false);
        if (err) { setError(String(err)); return; }
        try {
          const parsed = JSON.parse(res);
          if (parsed.error) setError(parsed.error);
          else setResult(parsed.data);
        } catch { setError('Failed to parse result'); }
      });
    }
  };

  return (
    <div class="sparql-editor">
      <div class="query-lang-toggle" style={{ marginBottom: '6px', display: 'flex', gap: '4px' }}>
        <button class={`btn btn-sm ${lang === 'sparql' ? 'active' : ''}`} onClick={() => setLang('sparql')}>SPARQL</button>
        <button class={`btn btn-sm ${lang === 'prolog' ? 'active' : ''}`} onClick={() => setLang('prolog')}>Prolog</button>
      </div>
      <textarea
        class="sparql-input"
        value={query}
        onInput={(e) => setQuery((e.target as HTMLTextAreaElement).value)}
        rows={6}
        spellcheck={false}
        placeholder={lang === 'sparql' ? 'SELECT ?s ?p ?o WHERE { ?s ?p ?o } LIMIT 20' : 'findall(X, triple(_, _, X), Xs)'}
      />
      <button class="btn" onClick={run} disabled={running}>
        {running ? 'Running…' : '▶ Execute Query'}
      </button>
      {error && <div class="error-msg">{error}</div>}
      {result && <JsonViewer data={result} />}
    </div>
  );
}
