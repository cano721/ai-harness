export class CircuitBreaker {
  private failures = 0;
  private state: 'closed' | 'open' | 'half-open' = 'closed';
  private openedAt = 0;

  constructor(
    private readonly threshold: number = 3,
    private readonly resetTimeout: number = 60000,
  ) {}

  isOpen(): boolean {
    if (this.state === 'open') {
      if (Date.now() - this.openedAt >= this.resetTimeout) {
        this.state = 'half-open';
        return false;
      }
      return true;
    }
    return false;
  }

  recordSuccess(): void {
    this.failures = 0;
    this.state = 'closed';
    this.openedAt = 0;
  }

  recordFailure(): void {
    this.failures++;
    const shouldOpen = this.failures >= this.threshold || this.state === 'half-open';
    if (shouldOpen) {
      this.openedAt = Date.now();
      this.state = 'open';
    }
  }

  getState(): 'closed' | 'open' | 'half-open' {
    return this.state;
  }

  reset(): void {
    this.failures = 0;
    this.state = 'closed';
    this.openedAt = 0;
  }
}

export async function runWithGracefulDegradation<T>(
  fn: () => Promise<T>,
  fallback: T,
  onError?: (error: Error) => void,
): Promise<T> {
  try {
    return await fn();
  } catch (err) {
    const error = err instanceof Error ? err : new Error(String(err));
    onError?.(error);
    return fallback;
  }
}
