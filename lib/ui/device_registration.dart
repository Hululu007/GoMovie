import 'package:flutter/material.dart';

import '../local_store.dart';
import '../models.dart';
import '../webview_bridge.dart';
import 'app_scope.dart';
import 'update_prompt.dart';

var _devicesReady = false;

class DeviceRegistrationGate extends StatefulWidget {
  const DeviceRegistrationGate({
    super.key,
    required this.store,
    required this.child,
  });
  final LocalStore store;
  final Widget child;

  @override
  State<DeviceRegistrationGate> createState() => _DeviceRegistrationGateState();
}

class _DeviceRegistrationGateState extends State<DeviceRegistrationGate> {
  @override
  void initState() {
    super.initState();
    if (!_devicesReady) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _open());
    }
  }

  Future<void> _open() async {
    if (!mounted) return;
    _devicesReady = true;
    final repository = AppScope.of(context).repository;
    await WebViewBridge.ensureSpiderBridge(repository).catchError((_) {});
    if (!mounted) return;
    await runStartupChecks(context, widget.store);
    if (!mounted) return;
    for (final site in SourceSite.values.where((site) => site.devices)) {
      try {
        final ready = await repository.sourceDevices(site.id);
        if (!ready) {
          await repository.sourceDevices(site.id, register: true);
        }
      } catch (_) {}
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
