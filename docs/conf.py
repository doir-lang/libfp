# Configuration file for the Sphinx documentation builder.
#
# For the full list of built-in configuration values, see the documentation:
# https://www.sphinx-doc.org/en/master/usage/configuration.html

# -- Project information -----------------------------------------------------
# https://www.sphinx-doc.org/en/master/usage/configuration.html#project-information

project = 'libfp'
copyright = '2025, Joshua Dahl'
author = 'Joshua Dahl'

# -- General configuration ---------------------------------------------------
# https://www.sphinx-doc.org/en/master/usage/configuration.html#general-configuration

extensions = ['breathe', "myst_parser"]

templates_path = ['_templates']
exclude_patterns = ['_build', 'Thumbs.db', '.DS_Store']

myst_enable_extensions = ["colon_fence", "strikethrough"]


# -- Options for HTML output -------------------------------------------------
# https://www.sphinx-doc.org/en/master/usage/configuration.html#options-for-html-output

html_theme = 'sphinx_book_theme'

html_logo = "https://raw.githubusercontent.com/doir-lang/lib/refs/heads/main/docs/doir.svg"

html_theme_options = {
    "repository_url": "https://github.com/doir-lang/libfp",
    "use_repository_button": True,
    "collapse_navbar": True,
}

html_sidebars = {
   '**': ["navbar-logo.html", "icon-links.html", "search-button-field.html", "sbt-sidebar-nav.html"]#,''' 'globaltoc.html'],
}