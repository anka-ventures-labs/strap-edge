import 'dart:async';

import '../sync/reset_gate.dart';
import 'hub_push.dart';

class HubSyncCompletion {
  HubSyncCompletion(this.generation, this.resetGeneration);

  final String? generation;
  final int resetGeneration;
}

/// Bridges the shared durable history terminal to the first subsequent derive.
/// Both foreground and headless sync run in the main isolate (see ResetGate).
class HubSync {
  static HubSyncCompletion? _pending;

  static void recordCompletion(String? generation, int resetGeneration) {
    if (ResetGate.changedSince(resetGeneration)) return;
    _pending = HubSyncCompletion(generation, resetGeneration);
  }

  static HubSyncCompletion? get pending => _pending;

  static void afterDerive(HubSyncCompletion? completed) {
    if (completed == null) return;
    if (identical(_pending, completed)) _pending = null;
    if (ResetGate.changedSince(completed.resetGeneration)) return;
    unawaited(HubPush.instance.pushNow(generation: completed.generation));
  }
}
