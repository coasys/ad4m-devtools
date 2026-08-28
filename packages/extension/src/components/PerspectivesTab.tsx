import { useState, useEffect } from 'preact/hooks';
import { SparqlEditor } from './SparqlEditor';
import { JsonViewer } from './JsonViewer';
import { GraphView } from './GraphView';

type DetailTab = 'overview' | 'schema' | 'links' | 'graph' | 'query';

interface Props {
  perspectives: any[];
}

function evalInPage(expr: string): Promise<any> {
  return new Promise((resolve) => {
    if (typeof chrome !== 'undefined' && chrome.devtools?.inspectedWindow) {
      chrome.devtools.inspectedWindow.eval(expr, (result: any, err: any) => {
        if (err) { resolve(null); }
        else { resolve(result); }
      });
    } else {
      try { resolve(eval(expr)); } catch { resolve(null); }
    }
  });
}

// Run a SPARQL query via the bridge's runSparqlQuery.
// Uses base64 encoding to avoid all string-escaping issues with multi-line SPARQL.
async function runSparqlQuery(perspectiveId: string, query: string): Promise<any> {
  const queryB64 = btoa(unescape(encodeURIComponent(query)));
  const result = await evalInPage(`
    (async () => {
      const dt = window.__AD4M_DEVTOOLS__;
      if (!dt?.runSparqlQuery) return JSON.stringify({ error: 'No runSparqlQuery available — bridge may need updating' });
      try {
        const q = decodeURIComponent(escape(atob('${queryB64}')));
        const r = await dt.runSparqlQuery('${perspectiveId}', q);
        return JSON.stringify({ data: r });
      } catch(e) {
        return JSON.stringify({ error: e.message || String(e) });
      }
    })()
  `);
  if (!result) return null;
  try {
    const parsed = JSON.parse(result);
    if (parsed.error) throw new Error(parsed.error);
    return parsed.data;
  } catch (e: any) {
    if (e.message) throw e;
    return null;
  }
}

// SHACL discovery query — finds NodeShapes and their property constraints
const SHACL_DISCOVERY_QUERY = `
PREFIX sh: <http://www.w3.org/ns/shacl#>
PREFIX rdf: <http://www.w3.org/1999/02/22-rdf-syntax-ns#>
PREFIX rdfs: <http://www.w3.org/2000/01/rdf-schema#>

SELECT ?shape ?targetClass ?targetClassLabel ?propShape ?path ?datatype ?minCount ?maxCount ?nodeKind ?name ?description ?class
WHERE {
  ?shape a sh:NodeShape .
  OPTIONAL { ?shape sh:targetClass ?targetClass }
  OPTIONAL { ?targetClass rdfs:label ?targetClassLabel }
  OPTIONAL {
    ?shape sh:property ?propShape .
    ?propShape sh:path ?path .
    OPTIONAL { ?propShape sh:datatype ?datatype }
    OPTIONAL { ?propShape sh:minCount ?minCount }
    OPTIONAL { ?propShape sh:maxCount ?maxCount }
    OPTIONAL { ?propShape sh:nodeKind ?nodeKind }
    OPTIONAL { ?propShape sh:name ?name }
    OPTIONAL { ?propShape sh:description ?description }
    OPTIONAL { ?propShape sh:class ?class }
  }
}
ORDER BY ?shape ?path
`;

// Predicate frequency query — find the most used predicates
const PREDICATE_STATS_QUERY = `
SELECT ?predicate (COUNT(*) AS ?count)
WHERE {
  ?s ?predicate ?o .
}
GROUP BY ?predicate
ORDER BY DESC(?count)
LIMIT 50
`;

// Class instances query
const CLASS_INSTANCES_QUERY = `
PREFIX rdf: <http://www.w3.org/1999/02/22-rdf-syntax-ns#>
SELECT ?class (COUNT(?instance) AS ?count)
WHERE {
  ?instance rdf:type ?class .
}
GROUP BY ?class
ORDER BY DESC(?count)
`;

interface ShaclShape {
  uri: string;
  targetClass?: string;
  targetClassLabel?: string;
  properties: ShaclProperty[];
}

interface ShaclProperty {
  path: string;
  datatype?: string;
  minCount?: number;
  maxCount?: number;
  nodeKind?: string;
  name?: string;
  description?: string;
  class?: string;
}

function parseShaclResults(results: any): ShaclShape[] {
  if (!results) return [];

  // Handle SPARQL JSON results format
  let bindings: any[] = [];
  if (results.results?.bindings) {
    bindings = results.results.bindings;
  } else if (Array.isArray(results)) {
    bindings = results;
  } else if (typeof results === 'string') {
    try {
      const parsed = JSON.parse(results);
      bindings = parsed.results?.bindings || parsed || [];
    } catch { return []; }
  }

  const shapeMap = new Map<string, ShaclShape>();

  for (const row of bindings) {
    const shapeUri = row.shape?.value || row.shape || '';
    if (!shapeUri) continue;

    let shape = shapeMap.get(shapeUri);
    if (!shape) {
      shape = {
        uri: shapeUri,
        targetClass: row.targetClass?.value || row.targetClass,
        targetClassLabel: row.targetClassLabel?.value || row.targetClassLabel,
        properties: [],
      };
      shapeMap.set(shapeUri, shape);
    }

    const path = row.path?.value || row.path;
    if (path) {
      shape.properties.push({
        path,
        datatype: row.datatype?.value || row.datatype,
        minCount: row.minCount?.value != null ? Number(row.minCount.value ?? row.minCount) : undefined,
        maxCount: row.maxCount?.value != null ? Number(row.maxCount.value ?? row.maxCount) : undefined,
        nodeKind: row.nodeKind?.value || row.nodeKind,
        name: row.name?.value || row.name,
        description: row.description?.value || row.description,
        class: row.class?.value || row.class,
      });
    }
  }

  return Array.from(shapeMap.values());
}

function parseStatsResults(results: any): Array<{ uri: string; count: number }> {
  let bindings: any[] = [];
  if (results?.results?.bindings) bindings = results.results.bindings;
  else if (Array.isArray(results)) bindings = results;
  else if (typeof results === 'string') {
    try {
      const parsed = JSON.parse(results);
      bindings = parsed.results?.bindings || parsed || [];
    } catch { return []; }
  }

  return bindings.map(row => ({
    uri: row.predicate?.value || row.class?.value || row.predicate || row.class || '',
    count: Number(row.count?.value || row.count || 0),
  })).filter(r => r.uri);
}

function shortUri(uri: string): string {
  if (!uri) return '';
  // Common prefix replacements
  const prefixes: [string, string][] = [
    ['http://www.w3.org/1999/02/22-rdf-syntax-ns#', 'rdf:'],
    ['http://www.w3.org/2000/01/rdf-schema#', 'rdfs:'],
    ['http://www.w3.org/ns/shacl#', 'sh:'],
    ['http://www.w3.org/2001/XMLSchema#', 'xsd:'],
    ['http://schema.org/', 'schema:'],
  ];
  for (const [prefix, short] of prefixes) {
    if (uri.startsWith(prefix)) return short + uri.slice(prefix.length);
  }
  // Fall back to last segment
  const last = uri.split(/[/#]/).pop();
  return last || uri;
}

const STATE_COLORS: Record<string, string> = {
  Private: '#569cd6',
  Synced: '#4ec9b0',
  LinkLanguageFailedToInstall: '#f44747',
  LinkLanguageInstalledButNotSynced: '#dcdcaa',
  NeighbourhoodCreationInitiated: '#dcdcaa',
  NeighbourhoodJoinInitiated: '#dcdcaa',
};

const LINKS_PAGE_SIZE = 50;

export function PerspectivesTab({ perspectives: passivePerspectives }: Props) {
  const [perspectives, setPerspectives] = useState<any[]>([]);
  const [selected, setSelected] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);
  const [detailTab, setDetailTab] = useState<DetailTab>('overview');

  // Links state
  const [links, setLinks] = useState<any[]>([]);
  const [linksLoading, setLinksLoading] = useState(false);
  const [linkFilter, setLinkFilter] = useState({ source: '', predicate: '', target: '' });
  const [linksPage, setLinksPage] = useState(0);
  const [linkGroupBy, setLinkGroupBy] = useState<'none' | 'predicate' | 'source'>('none');

  // Schema state
  const [shaclShapes, setShaclShapes] = useState<ShaclShape[]>([]);
  const [predicateStats, setPredicateStats] = useState<Array<{ uri: string; count: number }>>([]);
  const [classStats, setClassStats] = useState<Array<{ uri: string; count: number }>>([]);
  const [schemaLoading, setSchemaLoading] = useState(false);
  const [schemaError, setSchemaError] = useState<string | null>(null);

  // Show passively collected perspectives when available
  useEffect(() => {
    if (passivePerspectives.length > 0 && perspectives.length === 0) {
      setPerspectives(passivePerspectives);
    }
  }, [passivePerspectives]);

  const loadPerspectives = () => {
    setLoading(true);
    const expr = `
      (async () => {
        const dt = window.__AD4M_DEVTOOLS__;
        if (!dt?.getPerspectives) return null;
        const ps = await dt.getPerspectives();
        return JSON.stringify(ps);
      })()
    `;
    if (typeof chrome !== 'undefined' && chrome.devtools?.inspectedWindow) {
      chrome.devtools.inspectedWindow.eval(expr, (result: any, err: any) => {
        setLoading(false);
        if (result) {
          try { setPerspectives(JSON.parse(result)); } catch {}
        }
      });
    }
  };

  const loadLinks = () => {
    if (!selected) return;
    setLinksLoading(true);
    const filterObj: any = {};
    if (linkFilter.source) filterObj.source = linkFilter.source;
    if (linkFilter.predicate) filterObj.predicate = linkFilter.predicate;
    if (linkFilter.target) filterObj.target = linkFilter.target;
    const filterStr = JSON.stringify(filterObj).replace(/'/g, "\\'");
    const expr = `
      (async () => {
        const dt = window.__AD4M_DEVTOOLS__;
        if (!dt?.queryLinks) return '[]';
        const links = await dt.queryLinks('${selected}', ${filterStr});
        return JSON.stringify(links || []);
      })()
    `;
    if (typeof chrome !== 'undefined' && chrome.devtools?.inspectedWindow) {
      chrome.devtools.inspectedWindow.eval(expr, (res: any, err: any) => {
        setLinksLoading(false);
        if (res) { try { setLinks(JSON.parse(res)); setLinksPage(0); } catch {} }
      });
    }
  };

  const loadSchema = async () => {
    if (!selected) return;
    setSchemaLoading(true);
    setSchemaError(null);
    const errors: string[] = [];
    try {
      // Run all three queries in parallel
      const [shaclResult, predResult, classResult] = await Promise.all([
        runSparqlQuery(selected, SHACL_DISCOVERY_QUERY).catch((e: any) => { errors.push(`SHACL: ${e.message}`); return null; }),
        runSparqlQuery(selected, PREDICATE_STATS_QUERY).catch((e: any) => { errors.push(`Predicates: ${e.message}`); return null; }),
        runSparqlQuery(selected, CLASS_INSTANCES_QUERY).catch((e: any) => { errors.push(`Classes: ${e.message}`); return null; }),
      ]);
      setShaclShapes(parseShaclResults(shaclResult));
      setPredicateStats(parseStatsResults(predResult));
      setClassStats(parseStatsResults(classResult));
      if (errors.length > 0) setSchemaError(errors.join(' | '));
    } catch (e: any) {
      setSchemaError(e.message || 'Schema query failed');
    } finally {
      setSchemaLoading(false);
    }
  };

  const selectedPerspective = perspectives.find(p => p.uuid === selected);

  const pagedLinks = links.slice(linksPage * LINKS_PAGE_SIZE, (linksPage + 1) * LINKS_PAGE_SIZE);
  const totalPages = Math.ceil(links.length / LINKS_PAGE_SIZE);

  // Group links by predicate or source
  const groupedLinks = (() => {
    if (linkGroupBy === 'none') return null;
    const groups = new Map<string, any[]>();
    for (const link of links) {
      const key = linkGroupBy === 'predicate'
        ? (link.data?.predicate || link.predicate || '(none)')
        : (link.data?.source || link.source || '(none)');
      const arr = groups.get(key) || [];
      arr.push(link);
      groups.set(key, arr);
    }
    return Array.from(groups.entries()).sort((a, b) => b[1].length - a[1].length);
  })();

  return (
    <div class="tab-panel">
      <div class="perspectives-header">
        <h2>Perspectives</h2>
        <button class="btn" onClick={loadPerspectives} disabled={loading}>
          {loading ? 'Loading…' : '↻ Refresh'}
        </button>
      </div>

      <div class="perspective-list">
        {perspectives.map(p => (
          <div
            key={p.uuid}
            class={`perspective-item ${selected === p.uuid ? 'selected' : ''}`}
            onClick={() => {
              setSelected(p.uuid);
              setLinks([]);
              setShaclShapes([]);
              setPredicateStats([]);
              setClassStats([]);
              setSchemaError(null);
            }}
          >
            <span class="perspective-name">{p.name || 'Unnamed'}</span>
            <span class="perspective-uuid">{p.uuid.slice(0, 8)}…</span>
            {p.state && (
              <span
                class="perspective-state-badge"
                style={{ color: STATE_COLORS[p.state] || '#888' }}
              >
                {p.state}
              </span>
            )}
            {p.neighbourhood && <span class="badge">Shared</span>}
          </div>
        ))}
        {perspectives.length === 0 && !loading && (
          <p class="empty">Click Refresh to load perspectives</p>
        )}
      </div>

      {selected && selectedPerspective && (
        <div class="perspective-detail">
          <div class="sub-tab-bar">
            <button class={`sub-tab-btn ${detailTab === 'overview' ? 'active' : ''}`} onClick={() => setDetailTab('overview')}>Overview</button>
            <button class={`sub-tab-btn ${detailTab === 'schema' ? 'active' : ''}`} onClick={() => setDetailTab('schema')}>
              Schema {shaclShapes.length > 0 ? `(${shaclShapes.length})` : ''}
            </button>
            <button class={`sub-tab-btn ${detailTab === 'links' ? 'active' : ''}`} onClick={() => setDetailTab('links')}>Links ({links.length})</button>
            <button class={`sub-tab-btn ${detailTab === 'graph' ? 'active' : ''}`} onClick={() => setDetailTab('graph')}>Graph</button>
            <button class={`sub-tab-btn ${detailTab === 'query' ? 'active' : ''}`} onClick={() => setDetailTab('query')}>Query</button>
          </div>

          {/* ─── Overview ─── */}
          {detailTab === 'overview' && (
            <div class="overview-panel">
              <div class="info-grid">
                <div class="info-row">
                  <span class="info-label">UUID</span>
                  <span class="mono">{selectedPerspective.uuid}</span>
                </div>
                <div class="info-row">
                  <span class="info-label">Name</span>
                  <span>{selectedPerspective.name || '(unnamed)'}</span>
                </div>
                <div class="info-row">
                  <span class="info-label">State</span>
                  <span style={{ color: STATE_COLORS[selectedPerspective.state] || '#888', fontWeight: 'bold' }}>
                    {selectedPerspective.state || 'Unknown'}
                  </span>
                </div>
                {selectedPerspective.sharedUrl && (
                  <div class="info-row">
                    <span class="info-label">Shared URL</span>
                    <span class="mono">{selectedPerspective.sharedUrl}</span>
                  </div>
                )}
              </div>

              {selectedPerspective.neighbourhood && (
                <div class="neighbourhood-section">
                  <h4>Neighbourhood</h4>
                  <JsonViewer data={selectedPerspective.neighbourhood} />
                </div>
              )}

              <div class="overview-state-explainer">
                <h4>Link Language States</h4>
                <div class="state-legend">
                  {Object.entries(STATE_COLORS).map(([state, color]) => (
                    <div key={state} class="state-legend-item">
                      <span class="legend-dot" style={{ background: color }} />
                      <span>{state}</span>
                    </div>
                  ))}
                </div>
              </div>
            </div>
          )}

          {/* ─── Schema ─── */}
          {detailTab === 'schema' && (
            <div class="schema-panel">
              <button class="btn" onClick={loadSchema} disabled={schemaLoading}>
                {schemaLoading ? 'Loading…' : '↻ Load Schema'}
              </button>

              {schemaError && (
                <div class="error-msg" style={{ margin: '8px 0' }}>{schemaError}</div>
              )}

              {/* SHACL Shapes */}
              {shaclShapes.length > 0 && (
                <div class="schema-section">
                  <h4>SHACL Shapes ({shaclShapes.length})</h4>
                  {shaclShapes.map((shape, i) => (
                    <div key={i} class="shacl-shape">
                      <div class="shacl-shape-header">
                        <span class="shacl-shape-name">{shortUri(shape.uri)}</span>
                        {shape.targetClass && (
                          <span class="shacl-target">
                            → {shape.targetClassLabel || shortUri(shape.targetClass)}
                          </span>
                        )}
                      </div>
                      {shape.properties.length > 0 && (
                        <table class="shacl-props-table">
                          <thead>
                            <tr>
                              <th>Property</th>
                              <th>Type</th>
                              <th>Card.</th>
                              <th>Description</th>
                            </tr>
                          </thead>
                          <tbody>
                            {shape.properties.map((prop, j) => (
                              <tr key={j}>
                                <td class="mono">{prop.name || shortUri(prop.path)}</td>
                                <td class="mono">
                                  {prop.datatype ? shortUri(prop.datatype)
                                    : prop.class ? shortUri(prop.class)
                                    : prop.nodeKind ? shortUri(prop.nodeKind)
                                    : '-'}
                                </td>
                                <td>
                                  {prop.minCount != null || prop.maxCount != null
                                    ? `${prop.minCount ?? 0}..${prop.maxCount ?? '*'}`
                                    : '-'}
                                </td>
                                <td>{prop.description || '-'}</td>
                              </tr>
                            ))}
                          </tbody>
                        </table>
                      )}
                      {shape.properties.length === 0 && (
                        <p class="empty" style="padding: 4px 0">No property constraints defined</p>
                      )}
                    </div>
                  ))}
                </div>
              )}

              {/* Predicate Statistics */}
              {predicateStats.length > 0 && (
                <div class="schema-section">
                  <h4>Predicate Usage (top {predicateStats.length})</h4>
                  <table class="stats-table">
                    <thead>
                      <tr><th>Predicate</th><th>Count</th></tr>
                    </thead>
                    <tbody>
                      {predicateStats.map((stat, i) => (
                        <tr key={i}>
                          <td class="mono" title={stat.uri}>{shortUri(stat.uri)}</td>
                          <td>{stat.count}</td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                </div>
              )}

              {/* Class Statistics */}
              {classStats.length > 0 && (
                <div class="schema-section">
                  <h4>RDF Classes</h4>
                  <table class="stats-table">
                    <thead>
                      <tr><th>Class</th><th>Instances</th></tr>
                    </thead>
                    <tbody>
                      {classStats.map((stat, i) => (
                        <tr key={i}>
                          <td class="mono" title={stat.uri}>{shortUri(stat.uri)}</td>
                          <td>{stat.count}</td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                </div>
              )}

              {shaclShapes.length === 0 && predicateStats.length === 0 && classStats.length === 0 && !schemaLoading && (
                <p class="empty">Click "Load Schema" to discover SHACL shapes and graph statistics</p>
              )}
            </div>
          )}

          {/* ─── Links ─── */}
          {detailTab === 'links' && (
            <div class="links-panel">
              <div class="link-filters">
                <input class="filter-input" placeholder="Source…" value={linkFilter.source}
                  onInput={(e) => setLinkFilter(f => ({ ...f, source: (e.target as HTMLInputElement).value }))} />
                <input class="filter-input" placeholder="Predicate…" value={linkFilter.predicate}
                  onInput={(e) => setLinkFilter(f => ({ ...f, predicate: (e.target as HTMLInputElement).value }))} />
                <input class="filter-input" placeholder="Target…" value={linkFilter.target}
                  onInput={(e) => setLinkFilter(f => ({ ...f, target: (e.target as HTMLInputElement).value }))} />
                <button class="btn" onClick={loadLinks} disabled={linksLoading}>
                  {linksLoading ? 'Loading…' : 'Query Links'}
                </button>
              </div>

              {links.length > 0 && (
                <div class="link-toolbar">
                  <span class="link-count">{links.length} links</span>
                  <div class="link-group-controls">
                    <span class="info-label">Group by:</span>
                    <button class={`btn btn-sm ${linkGroupBy === 'none' ? 'active' : ''}`}
                      onClick={() => setLinkGroupBy('none')}>None</button>
                    <button class={`btn btn-sm ${linkGroupBy === 'predicate' ? 'active' : ''}`}
                      onClick={() => setLinkGroupBy('predicate')}>Predicate</button>
                    <button class={`btn btn-sm ${linkGroupBy === 'source' ? 'active' : ''}`}
                      onClick={() => setLinkGroupBy('source')}>Source</button>
                  </div>
                </div>
              )}

              {links.length > 0 && linkGroupBy === 'none' && (
                <>
                  <table class="links-table">
                    <thead>
                      <tr><th>Source</th><th>Predicate</th><th>Target</th><th>Author</th><th>Timestamp</th></tr>
                    </thead>
                    <tbody>
                      {pagedLinks.map((link: any, i: number) => (
                        <tr key={i}>
                          <td class="mono" title={link.data?.source}>{shortUri(link.data?.source || '')}</td>
                          <td class="mono" title={link.data?.predicate}>{shortUri(link.data?.predicate || '')}</td>
                          <td class="mono" title={link.data?.target}>{shortUri(link.data?.target || '')}</td>
                          <td class="mono">{(link.author || '').slice(0, 15)}…</td>
                          <td>{link.timestamp ? new Date(link.timestamp).toLocaleTimeString() : '-'}</td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                  {totalPages > 1 && (
                    <div class="pagination">
                      <button class="btn btn-sm" disabled={linksPage === 0} onClick={() => setLinksPage(p => p - 1)}>← Prev</button>
                      <span>Page {linksPage + 1} / {totalPages}</span>
                      <button class="btn btn-sm" disabled={linksPage >= totalPages - 1} onClick={() => setLinksPage(p => p + 1)}>Next →</button>
                    </div>
                  )}
                </>
              )}

              {links.length > 0 && groupedLinks && (
                <div class="link-groups">
                  {groupedLinks.map(([group, groupLinks]) => (
                    <details key={group} class="link-group">
                      <summary class="link-group-header">
                        <span class="mono">{shortUri(group)}</span>
                        <span class="link-group-count">{groupLinks.length}</span>
                      </summary>
                      <table class="links-table">
                        <thead>
                          <tr>
                            {linkGroupBy === 'predicate' ? (
                              <><th>Source</th><th>Target</th><th>Author</th><th>Timestamp</th></>
                            ) : (
                              <><th>Predicate</th><th>Target</th><th>Author</th><th>Timestamp</th></>
                            )}
                          </tr>
                        </thead>
                        <tbody>
                          {groupLinks.slice(0, 50).map((link: any, i: number) => (
                            <tr key={i}>
                              {linkGroupBy === 'predicate' ? (
                                <td class="mono" title={link.data?.source}>{shortUri(link.data?.source || '')}</td>
                              ) : (
                                <td class="mono" title={link.data?.predicate}>{shortUri(link.data?.predicate || '')}</td>
                              )}
                              <td class="mono" title={link.data?.target}>{shortUri(link.data?.target || '')}</td>
                              <td class="mono">{(link.author || '').slice(0, 15)}…</td>
                              <td>{link.timestamp ? new Date(link.timestamp).toLocaleTimeString() : '-'}</td>
                            </tr>
                          ))}
                          {groupLinks.length > 50 && (
                            <tr><td colSpan={4} class="empty">… and {groupLinks.length - 50} more</td></tr>
                          )}
                        </tbody>
                      </table>
                    </details>
                  ))}
                </div>
              )}

              {links.length === 0 && !linksLoading && <p class="empty">Click "Query Links" to browse links</p>}
            </div>
          )}

          {/* ─── Graph ─── */}
          {detailTab === 'graph' && (
            <div class="graph-panel">
              {links.length === 0 && (
                <div class="graph-load-prompt">
                  <p class="empty">Load links first to visualise the graph.</p>
                  <button class="btn" onClick={() => { setDetailTab('links'); setTimeout(loadLinks, 100); }}>
                    Load Links
                  </button>
                </div>
              )}
              {links.length > 0 && <GraphView links={links} />}
            </div>
          )}

          {/* ─── Query ─── */}
          {detailTab === 'query' && <SparqlEditor perspectiveUUID={selected} />}
        </div>
      )}
    </div>
  );
}
