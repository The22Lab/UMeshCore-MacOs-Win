#include "umeshcore/Interop/EditorSession.h"

namespace umeshcore {

EditorSession* makeEditorSession() { return new EditorSession(); }

void destroyEditorSession(EditorSession* session) { delete session; }

} // namespace umeshcore
