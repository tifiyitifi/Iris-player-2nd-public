import 'package:iris/features/scenario_playback/model/enum/scenario_source_kind.dart';

/// A prospective `ScenarioSource` row — the ONE source-spec type shared by the
/// repository, the store and the play actions.
///
/// A directory to play is just a folder spec: `kind: ScenarioSourceKind.folder`
/// with an empty `path` meaning the storage root.
typedef ScenarioSourceSpec = ({
  String storageId,
  String path,
  bool recursive,
  ScenarioSourceKind kind,
});
