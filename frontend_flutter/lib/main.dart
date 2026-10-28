import 'package:flutter/material.dart';

import 'app.dart';
import 'state/app_scope.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final state = await AppState.bootstrap();
  runApp(AppScope(
    state: state,
    child: const UuDeskApp(),
  ));
}
