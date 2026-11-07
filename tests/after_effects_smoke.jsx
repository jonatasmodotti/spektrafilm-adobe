// Execute manually in After Effects: File > Scripts > Run Script File.
// Adds a disposable composition; does not close, replace or save the project.
(function () {
    if (!app.project) app.newProject();
    app.beginUndoGroup("spektrafilm smoke test");
    try {
        var comp = app.project.items.addComp("spektrafilm Adobe smoke", 128, 128, 1, 1, 24);
        var layer = comp.layers.addSolid([0.18, 0.35, 0.6], "Test source", 128, 128, 1, 1);
        var effects = layer.property("ADBE Effect Parade");
        if (!effects.canAddProperty("org.spektrafilm.adobe")) {
            throw new Error("spektrafilm is not registered. Install the plugin and restart After Effects.");
        }
        var effect = effects.addProperty("org.spektrafilm.adobe");
        if (!effect || effect.numProperties < 9) throw new Error("Effect parameters were not registered.");
        comp.openInViewer();
        layer.selected = true;
        alert("spektrafilm is registered and applied. Check the preview, then export a frame to verify rendering. This is a smoke test, not a visual parity test.");
    } catch (error) {
        alert("spektrafilm smoke test failed: " + error.toString());
    } finally {
        app.endUndoGroup();
    }
})();
