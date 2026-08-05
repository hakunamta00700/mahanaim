import std/[os, tables, unittest]
import mahanaim/templates

suite "Template files":
  test "loads nested HTML templates by relative path":
    let root = getTempDir() / "mahanaim_template_directory_test"
    let layouts = root / "layouts"
    let pages = root / "pages"
    if dirExists(root):
      removeDir(root)
    createDir(root)
    createDir(layouts)
    createDir(pages)
    writeFile(layouts / "base.html",
      "<main>{% block content %}fallback{% endblock %}</main>")
    writeFile(pages / "home.html",
      "{% extends \"layouts/base\" %}{% block content %}<h1>{{ title }}</h1>{% endblock %}")
    writeFile(root / "ignored.txt", "not a template")
    try:
      let engine = newTemplateEngine()
      engine.loadTemplateDirectory(root)
      var context = initTable[string, string]()
      context["title"] = "File template"
      check engine.render("pages/home", context) ==
        "<main><h1>File template</h1></main>"
      expect ValueError:
        engine.loadTemplateDirectory(root)
      expect ValueError:
        newTemplateEngine().loadTemplateDirectory(root / "missing")
    finally:
      if dirExists(root):
        removeDir(root)

