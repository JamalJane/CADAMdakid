import * as Sentry from 'npm:@sentry/deno';

// Initialize Sentry with environment-specific configuration
export function initSentry() {
  Sentry.init({
    dsn: Deno.env.get('SENTRY_DSN') ?? '',
    defaultIntegrations: false,
    tracesSampleRate: 0.1,
    environment: Deno.env.get('ENVIRONMENT') ?? 'development',
  });
}

// Log errors with context for edge function failures
export function logError(
  error: Error | unknown,
  context: {
    functionName: string;
    statusCode: number;
    userId?: string;
    conversationId?: string;
    additionalContext?: Record<string, unknown>;
  },
) {
  const errorMessage = error instanceof Error ? error.message : 'Unknown error';
  const errorStack = error instanceof Error ? error.stack : undefined;

  Sentry.captureException(error, {
    tags: {
      function: context.functionName,
      statusCode: context.statusCode.toString(),
      environment: Deno.env.get('ENVIRONMENT') ?? 'development',
    },
    extra: {
      userId: context.userId,
      conversationId: context.conversationId,
      errorMessage,
      errorStack,
      ...context.additionalContext,
    },
    level: context.statusCode >= 500 ? 'error' : 'warning',
  });

  // Also log to console for immediate debugging
  console.error(`[${context.functionName}] Error (${context.statusCode}):`, {
    error: errorMessage,
    userId: context.userId,
    conversationId: context.conversationId,
    additionalContext: context.additionalContext,
  });
}

// Log API errors with additional context
export function logApiError(
  error: Error | unknown,
  context: {
    functionName: string;
    apiName: string;
    statusCode: number;
    userId?: string;
    conversationId?: string;
    requestData?: Record<string, unknown>;
  },
) {
  logError(error, {
    functionName: context.functionName,
    statusCode: context.statusCode,
    userId: context.userId,
    conversationId: context.conversationId,
    additionalContext: {
      apiName: context.apiName,
      requestData: context.requestData,
    },
  });
}
