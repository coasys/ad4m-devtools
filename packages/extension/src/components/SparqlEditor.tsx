import { useState } from 'preact/hooks';
import { JsonViewer } from './JsonViewer';

interface Props {
  perspectiveUUID: string;
}

export function SparqlEditor({ perspectiveUUID }: Props) {
  const [query, setQuery] = useState('findall(X, triple(_, _, X), Xs)');
  const [result, setResult] = useState<any>(null);
  const [error, setError] = useState<string | null>(null);
  const [running, setRunning] = useState(false);

  const run = () => {
    setRunning(true);
    setError(null);
    setResult(null);
    const escaped = query.replace(/\\/g, '\\\\').replace(/'/g, "\\'").replace(/\n/g, '\\n').replace(/`/g, '\\`').replace(/\$/g, '\\$');
    const expr = `
      (async () => {
        const dt = window.__AD4M_DEVTOOLS__;
        if (!dt?.runQuery) return JSON.stringify({ error: 'No query method available' });
        try {
          const r = await dt.runQuery('${perspectiveUUID}', '${escaped}');
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
      <textarea
        class="sparql-input"
        value={query}
        onInput={(e) => setQuery((e.target as HTMLTextAreaElement).value)}
        rows={6}
        spellcheck={false}
        placeholder="Enter a Prolog query..."
      />
      <button class="btn" onClick={run} disabled={running}>
        {running ? 'Running...' : '▶ Execute Query'}
      </button>
      {error && <div class="error-msg">{error}</div>}
      {result && <JsonViewer data={result} />}
    </div>
  );
}
