type Handler = (...args: any[]) => void;

/** Minimal event emitter used for decoupled game events (damage, kills, waves...). */
export class EventBus {
  private handlers = new Map<string, Set<Handler>>();

  on(event: string, fn: Handler): () => void {
    let set = this.handlers.get(event);
    if (!set) {
      set = new Set();
      this.handlers.set(event, set);
    }
    set.add(fn);
    return () => set!.delete(fn);
  }

  emit(event: string, ...args: any[]): void {
    const set = this.handlers.get(event);
    if (!set) return;
    for (const fn of [...set]) fn(...args);
  }

  clear(): void {
    this.handlers.clear();
  }
}
