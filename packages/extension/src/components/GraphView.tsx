import { useRef, useEffect, useState } from 'preact/hooks';

interface GraphNode {
  id: string;
  label: string;
  group: string; // 'subject' | 'object' | 'literal'
  val: number;   // node size weight
}

interface GraphLink {
  source: string;
  target: string;
  predicate: string;
  color: string;
}

interface Props {
  links: any[];
  width?: number;
  height?: number;
}

// Deterministic colour from a predicate string
function predicateColor(pred: string): string {
  let hash = 0;
  for (let i = 0; i < pred.length; i++) {
    hash = ((hash << 5) - hash + pred.charCodeAt(i)) | 0;
  }
  const hue = ((hash % 360) + 360) % 360;
  return `hsl(${hue}, 65%, 55%)`;
}

function truncate(s: string, max = 28): string {
  if (s.length <= max) return s;
  // Keep the last segment after / or # for URIs
  const lastSeg = s.split(/[/#]/).pop();
  if (lastSeg && lastSeg.length <= max) return lastSeg;
  return s.slice(0, max - 1) + '…';
}

function buildGraph(links: any[]): { nodes: GraphNode[]; links: GraphLink[] } {
  const nodeMap = new Map<string, GraphNode>();
  const graphLinks: GraphLink[] = [];

  const ensureNode = (id: string, group: string) => {
    if (!id) return;
    const existing = nodeMap.get(id);
    if (existing) {
      existing.val += 1;
    } else {
      nodeMap.set(id, {
        id,
        label: truncate(id),
        group,
        val: 1,
      });
    }
  };

  for (const link of links) {
    const source = link.data?.source || link.source || '';
    const target = link.data?.target || link.target || '';
    const predicate = link.data?.predicate || link.predicate || '';
    if (!source || !target) continue;

    ensureNode(source, 'subject');
    // Heuristic: targets starting with "literal://" or containing no "://" are literals
    const isLiteral = target.startsWith('literal://') || !target.includes('://');
    ensureNode(target, isLiteral ? 'literal' : 'object');

    graphLinks.push({
      source,
      target,
      predicate: truncate(predicate, 40),
      color: predicateColor(predicate),
    });
  }

  return { nodes: Array.from(nodeMap.values()), links: graphLinks };
}

const GROUP_COLORS: Record<string, string> = {
  subject: '#569cd6',
  object: '#4ec9b0',
  literal: '#dcdcaa',
};

export function GraphView({ links, width, height }: Props) {
  const containerRef = useRef<HTMLDivElement>(null);
  const graphRef = useRef<any>(null);
  const [error, setError] = useState<string | null>(null);
  const [nodeCount, setNodeCount] = useState(0);

  useEffect(() => {
    if (!containerRef.current || links.length === 0) return;

    let mounted = true;

    (async () => {
      try {
        // Dynamic import — 3d-force-graph bundles three.js
        const ForceGraph3DModule = await import('3d-force-graph');
        const ForceGraph3D = ForceGraph3DModule.default || ForceGraph3DModule;

        if (!mounted || !containerRef.current) return;

        const { nodes, links: graphLinks } = buildGraph(links);
        setNodeCount(nodes.length);

        // Clear previous instance
        if (graphRef.current) {
          graphRef.current._destructor?.();
          containerRef.current.innerHTML = '';
        }

        const w = width || containerRef.current.clientWidth || 600;
        const h = height || 400;

        const graph = ForceGraph3D()(containerRef.current)
          .width(w)
          .height(h)
          .backgroundColor('#1e1e1e')
          .nodeLabel((node: any) => node.id)
          .nodeColor((node: any) => GROUP_COLORS[node.group] || '#888')
          .nodeVal((node: any) => Math.max(1, Math.log2(node.val + 1)))
          .nodeOpacity(0.9)
          .linkLabel((link: any) => link.predicate)
          .linkColor((link: any) => link.color)
          .linkWidth(0.5)
          .linkDirectionalArrowLength(3)
          .linkDirectionalArrowRelPos(1)
          .linkOpacity(0.6)
          .graphData({ nodes, links: graphLinks });

        graphRef.current = graph;
      } catch (e: any) {
        if (mounted) setError(e.message || 'Failed to load 3D graph renderer');
      }
    })();

    return () => {
      mounted = false;
      if (graphRef.current) {
        graphRef.current._destructor?.();
        graphRef.current = null;
      }
    };
  }, [links, width, height]);

  if (links.length === 0) {
    return <p class="empty">Load links first to view the graph</p>;
  }

  return (
    <div class="graph-view">
      {error && <div class="error-msg">{error}</div>}
      <div class="graph-legend">
        <span class="graph-legend-item"><span class="legend-dot" style={{ background: GROUP_COLORS.subject }} /> Subject</span>
        <span class="graph-legend-item"><span class="legend-dot" style={{ background: GROUP_COLORS.object }} /> Object</span>
        <span class="graph-legend-item"><span class="legend-dot" style={{ background: GROUP_COLORS.literal }} /> Literal</span>
        <span class="graph-legend-count">{nodeCount} nodes, {links.length} links</span>
      </div>
      <div ref={containerRef} class="graph-container" />
    </div>
  );
}
