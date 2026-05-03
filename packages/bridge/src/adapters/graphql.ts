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
    // Fallback: JSON serialize the definitions
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
 * Creates an Apollo Link that intercepts all operations for DevTools.
 * Insert this as the first link in the chain.
 */
export function createDevToolsLink(bridge: DevToolsBridge): ApolloLink {
  return {
    request(operation: ApolloOperation, forward: any) {
      const opName = operation.operationName || getOperationName(operation.query);
      const opType = getOperationType(operation.query);
      const queryText = printQuery(operation.query);

      if (opType === 'subscription') {
        // Track subscriptions
        const subId = bridge.trackSubscription({
          query: queryText,
          modelName: opName,
          perspectiveUUID: operation.variables?.uuid || operation.variables?.perspectiveUuid || '',
        });

        const observable = forward(operation);
        
        // Wrap the observable to track updates
        return {
          subscribe(observer: any) {
            return observable.subscribe({
              next(result: any) {
                bridge.recordEventStreamMessage();
                bridge.updateSubscription(subId, {
                  updateCount: (bridge as any)._getSubUpdateCount?.(subId) ?? 1,
                  lastUpdateTimestamp: Date.now(),
                });
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
      const method = opType === 'mutation' ? 'POST' : 'POST'; // GraphQL always POST
      const opId = bridge.logOperation({
        type: 'request',
        transport: 'graphql' as any,
        operationName: `${opType.toUpperCase()} ${opName}`,
        method,
        path: `/graphql`,
        query: queryText,
        variables: operation.variables,
        requestBody: {
          query: queryText,
          variables: operation.variables,
          operationName: opName,
        },
      });

      const observable = forward(operation);

      return {
        subscribe(observer: any) {
          return observable.subscribe({
            next(result: any) {
              const errors = result?.errors;
              bridge.completeOperation(
                opId,
                result?.data,
                errors,
                { statusCode: errors?.length ? 200 : 200 }
              );
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
  
  // Prepend our link to the existing chain
  const originalLink = apolloClient.link;
  apolloClient.link = {
    request(operation: ApolloOperation, forward: any) {
      return devToolsLink.request(operation, (op: ApolloOperation) => {
        return originalLink.request(op, forward);
      });
    },
  };
}
