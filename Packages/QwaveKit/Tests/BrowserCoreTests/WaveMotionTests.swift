import JavaScriptCore
import XCTest
@testable import BrowserCore

final class WaveMotionTests: XCTestCase {
    private func scene(reduced: Bool, legacy: Bool = false) throws -> JSContext {
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript("""
            const pending = new Map();
            let nextID = 0, draws = 0, timeValue = null;
            const events = {}, mediaEvents = {};
            const media = { matches: \(reduced),
              addListener(fn) { mediaEvents.change = fn; } };
            if (!\(legacy)) media.addEventListener = (name, fn) => mediaEvents[name] = fn;
            const gl = new Proxy({}, { get(_, name) {
              if (name === 'getShaderParameter' || name === 'getProgramParameter') return () => true;
              if (name === 'drawArrays') return () => ++draws;
              if (name === 'uniform1f') return (_, value) => timeValue = value;
              return () => ({});
            }});
            const canvas = { getContext: () => gl };
            const window = { innerWidth: 400, innerHeight: 800, matchMedia: () => media,
              addEventListener(name, fn) { events[name] = fn; } };
            const document = { hidden: false,
              getElementById: name => name === 'glCanvas' ? canvas : { text: '' },
              addEventListener(name, fn) { events[name] = fn; } };
            const requestAnimationFrame = fn => { const id = ++nextID; pending.set(id, fn); return id; };
            const cancelAnimationFrame = id => pending.delete(id);
            function setMotion(value) { media.matches = value; if (mediaEvents.change) mediaEvents.change(); }
            function tick(time) { const callbacks = [...pending.values()]; pending.clear(); callbacks.forEach(fn => fn(time)); }
            """)
        context.evaluateScript(WaveScene.canvasScript)
        XCTAssertNil(context.exception)
        return context
    }

    private func check(_ context: JSContext, _ expression: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(context.evaluateScript(expression)?.toBool() == true, expression, file: file, line: line)
        XCTAssertNil(context.exception, file: file, line: line)
    }

    func testLivePreferenceStopsAndResumesOneLoop() throws {
        let context = try scene(reduced: false)
        check(context, "pending.size === 1")
        context.evaluateScript("tick(1000); setMotion(true)")
        check(context, "pending.size === 0 && draws === 2 && timeValue === 8")
        context.evaluateScript("setMotion(false); events.visibilitychange(); events.visibilitychange()")
        check(context, "pending.size === 1")
        context.evaluateScript("tick(2000)")
        check(context, "pending.size === 1 && timeValue === 2")
    }

    func testReducedMotionRepaintsAfterResizeAndVisibility() throws {
        let context = try scene(reduced: true)
        check(context, "draws === 1 && pending.size === 0")
        context.evaluateScript("window.innerWidth = 900; events.resize()")
        check(context, "canvas.width === 900 && draws === 2 && timeValue === 8")
        context.evaluateScript("document.hidden = true; events.visibilitychange(); events.resize(); setMotion(false)")
        check(context, "draws === 2 && pending.size === 0")
        context.evaluateScript("setMotion(true); document.hidden = false; events.visibilitychange()")
        check(context, "draws === 3 && pending.size === 0")
    }

    func testLegacyMediaListenerAndHiddenAnimation() throws {
        let context = try scene(reduced: false, legacy: true)
        context.evaluateScript("document.hidden = true; events.visibilitychange()")
        check(context, "pending.size === 0")
        context.evaluateScript("document.hidden = false; events.visibilitychange(); setMotion(true)")
        check(context, "pending.size === 0 && draws === 1 && timeValue === 8")
    }
}
