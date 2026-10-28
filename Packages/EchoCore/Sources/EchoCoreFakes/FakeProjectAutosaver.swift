import EchoCore

/// Records what was scheduled and how often it was flushed; saves nothing.
public actor FakeProjectAutosaver: ProjectAutosaving {
    public private(set) var scheduled: [Project] = []
    public private(set) var flushCount = 0

    public init() {}

    public func schedule(_ project: Project) {
        scheduled.append(project)
    }

    public func flush() {
        flushCount += 1
    }
}
