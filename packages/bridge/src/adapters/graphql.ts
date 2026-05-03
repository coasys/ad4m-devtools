import type { OperationRecord } from '../core/types';

/**
 * GraphQL/Apollo adapter for AD4M DevTools bridge.
 * 
 * Intercepts Apollo link chain operations and maps them to OperationRecord format.
 * Works with the `dev` branch of coasys/ad4m which uses ApolloClient.
 */

interface ApolloOperation {
  query: any;
  variables?: Record<string, any>;
  operationName?: string;
  getContext?: () => any;
  setContext?: (context: any) => any;
  extensions?: Record<string, any>;
}

interface ApolloLink {
  request: (operation: ApolloOperation, forward?: any) => any;
}

interface DevToolsBridge {
  logOperation(op: Partial<OperationRecord>): number;
  completeOperation(id: number, result: any, errors?: any[], options?: any): void;
  trackSubscription(sub: any): number;
  updateSubscription(id: number, update: any): void;
  recordEventStreamMessage(): void;
  logSparqlQuery?(info: { query: string; modelName: string; perspectiveUUID: string }): void;
}

/**
 * Extracts the operation name from a GraphQL document node.
 */
function getOperationName(query: any): string {
  if (!query?.definitions) return 'unknown';
  for (const def of query.definitions) {
    if (def.kind === 'OperationDefinition' && def.name?.value) {
      return def.name.value;
    }
  }
  return 'anonymous';
}

/**
 * Extracts the operation type (query/mutation/subscription) from a GraphQL document.
 */
function getOperationType(query: any): string {
  if (!query?.definitions) return 'query';
  for (const def of query.definitions) {
    if (def.kind === 'OperationDefinition') {
      return def.operation || 'query';
    }
  }
  return 'query';
}

/**
 * Serializes a GraphQL document to a string (uses .loc.source.body if available).
 */
function printQuery(query: any): string {
  if (typeof query === 'string') return query;
  if (query?.loc?.source?.body) return query.loc.source.body;
  try {
    return JSON.stringify(query?.definitions?.map((d: any) => ({
      operation: d.operation,
      name: d.name?.value,
      selections: d.selectionSet?.selections?.length,
    })));
  } catch {
    return '[unparseable query]';
  }
}

/**
 * SPARQL detection patterns — identifies SPARQL query text in variables or responses.
 */
const SPARQL_KEYWORDS = ['SELECT', 'CONSTRUCT', 'ASK', 'DESCRIBE', 'INSERT', 'DELETE', 'WHERE'];
const SPARQL_PATTERN = new RegExp(
  `\\b(${SPARQL_KEYWORDS.join('|')})\\b[\\s\\S]*\\b(WHERE|\\{)\\b`,
  'i'
);

/**
 * Attempts to extract SPARQL query text from variables or response data.
 */
function extractSparqlQuery(variables?: Record<string, any>): string | undefined {
  if (!variables) return undefined;
  
  // Check common variable names that might contain SPARQL
  const candidates = ['query', 'sparqlQuery', 'inferQuery', 'sparql', 'expression'];
  for (const key of candidates) {
    const value = variables[key];
    if (typeof value === 'string' && SPARQL_PATTERN.test(value)) {
      return value;
    }
  }
  
  // Check all string values
  for (const value of Object.values(variables)) {
    if (typeof value === 'string' && value.length > 20 && SPARQL_PATTERN.test(value)) {
      return value;
    }
  }
  
  return undefined;
}

/**
 * Scans response data for SPARQL query text (e.g. in perspectives.infer results).
 */
function extractSparqlFromResponse(data: any): string | undefined {
  if (!data) return undefined;
  
  // Recursively search for SPARQL-looking strings in response
  const searchObj = (obj: any, depth: number): string | undefined => {
    if (depth > 5) return undefined;
    if (typeof obj === 'string' && obj.length > 20 && SPARQL_PATTERN.test(obj)) {
      return obj;
    }
    if (Array.isArray(obj)) {
      for (const item of obj) {
        const found = searchObj(item, depth + 1);
        if (found) return found;
      }
    } else if (obj && typeof obj === 'object') {
      for (const value of Object.values(obj)) {
        const found = searchObj(value, depth + 1);
        if (found) return found;
      }
    }
    return undefined;
  };
  
  return searchObj(data, 0);
}

/**
 * Creates an Apollo Link that intercepts all operations for DevTools.
 * Enhanced with SPARQL trace enrichment for the sparql-1.2-cleanup branch.
 */
export function createDevToolsLink(bridge: DevToolsBridge): ApolloLink {
  return {
    request(operation: ApolloOperation, forward: any) {
      const opName = operation.operationName || getOperationName(operation.query);
      const opType = getOperationType(operation.query);
      const queryText = printQuery(operation.query);

      // Check if this operation contains SPARQL in its variables
      const sparqlInVars = extractSparqlQuery(operation.variables);

      if (opType === 'subscription') {
        const subId = bridge.trackSubscription({
          query: queryText,
          modelName: opName,
          perspectiveUUID: operation.variables?.uuid || operation.variables?.perspectiveUuid || '',
        });

        const observable = forward(operation);
        
        return {
          subscribe(observer: any) {
            return observable.subscribe({
              next(result: any) {
                bridge.recordEventStreamMessage();
                bridge.updateSubscription(subId, {
                  lastUpdateTimestamp: Date.now(),
                });

                // Check subscription results for SPARQL content
                const sparqlInResult = extractSparqlFromResponse(result?.data);
                if (sparqlInResult && bridge.logSparqlQuery) {
                  bridge.logSparqlQuery({
                    query: sparqlInResult,
                    modelName: opName,
                    perspectiveUUID: operation.variables?.uuid || '',
                  });
                }

                observer.next?.(result);
              },
              error(err: any) {
                bridge.updateSubscription(subId, { active: false });
                observer.error?.(err);
              },
              complete() {
                bridge.updateSubscription(subId, { active: false });
                observer.complete?.();
              },
            });
          },
        };
      }

      // Queries and Mutations
      const opId = bridge.logOperation({
        type: 'request',
        transport: 'graphql' as any,
        operationName: `${opType.toUpperCase()} ${opName}`,
        method: 'POST',
        path: `/graphql`,
        query: queryText,
        queryLanguage: sparqlInVars ? 'sparql' : undefined,
        sparqlQuery: sparqlInVars,
        variables: operation.variables,
        requestBody: {
          query: queryText,
          variables: operation.variables,
          operationName: opName,
        },
      });

      // If we detected SPARQL in the variables, also log a SPARQL trace
      if (sparqlInVars && bridge.logSparqlQuery) {
        bridge.logSparqlQuery({
          query: sparqlInVars,
          modelName: opName,
          perspectiveUUID: operation.variables?.uuid || operation.variables?.perspectiveUuid || '',
        });
      }

      const observable = forward(operation);

      return {
        subscribe(observer: any) {
          return observable.subscribe({
            next(result: any) {
              const errors = result?.errors;

              // Check response for SPARQL content and enrich the operation
              const sparqlInResponse = extractSparqlFromResponse(result?.data);
              
              bridge.completeOperation(
                opId,
                result?.data,
                errors,
                { statusCode: 200 }
              );

              // Log additional SPARQL trace if found in response
              if (sparqlInResponse && !sparqlInVars && bridge.logSparqlQuery) {
                bridge.logSparqlQuery({
                  query: sparqlInResponse,
                  modelName: `${opName} (response)`,
                  perspectiveUUID: operation.variables?.uuid || '',
                });
              }

              observer.next?.(result);
            },
            error(err: any) {
              bridge.completeOperation(
                opId,
                null,
                [err],
                { statusCode: err?.statusCode || 500 }
              );
              observer.error?.(err);
            },
            complete() {
              observer.complete?.();
            },
          });
        },
      };
    },
  };
}

/**
 * Wraps an existing ApolloClient instance to intercept operations.
 * This patches the client's link chain by prepending a DevTools link.
 */
export function wrapApolloClient(apolloClient: any, bridge: DevToolsBridge): void {
  if (!apolloClient?.link) return;

  const devToolsLink = createDevToolsLink(bridge);
  
  const originalLink = apolloClient.link;
  apolloClient.link = {
    request(operation: ApolloOperation, forward: any) {
      return devToolsLink.request(operation, (op: ApolloOperation) => {
        return originalLink.request(op, forward);
      });
    },
  };
}
