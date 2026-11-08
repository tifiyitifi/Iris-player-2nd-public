import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/app_instance/model/new_window_request.dart';
import 'package:iris/features/app_instance/services/startup_open_request.dart';

/// A mirror-neighbour payload must count as a real startup action: otherwise a
/// spawned window would treat it as "no request" and run the generic resume,
/// playing whatever its own session held instead of the requested neighbour.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a mirror request is a startup action', () {
    expect(
      startupRequestHasAction(
        const NewWindowRequest(mirrorScenarioId: 'scn-1'),
      ),
      isTrue,
    );
    expect(
      startupRequestHasAction(
        const NewWindowRequest(mirrorScenarioId: 'scn-1', mirrorTagViewId: 7),
      ),
      isTrue,
    );
    expect(startupRequestHasAction(const NewWindowRequest()), isFalse,
        reason: 'a default payload carries no action');
  });

  test('a resolved neighbour target still counts as a startup action', () {
    expect(
      startupRequestHasAction(
        const NewWindowRequest(
          mirrorScenarioId: 'scn-1',
          mirrorTargetIndex: 4,
        ),
      ),
      isTrue,
    );
  });
}
