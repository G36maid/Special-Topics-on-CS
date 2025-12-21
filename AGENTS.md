# Agent Guidelines for LaTeX Project

This document outlines the guidelines for agents operating within this LaTeX project.

## Directory Structure
*   `src/`: LaTeX source code (`.tex`) and resources.
    *   `midterm_report.tex`: Midterm report source.
    *   `final_report.tex`: Final report source.
*   `report/`: Compiled PDF reports.
*   `experiment/`: Experiment code, data, or scripts.
*   `slide/`: Presentation slides.
*   `docs/`: Reference documents and literature.
*   `notes/`: Personal notes.

## Build Commands
*   `make all`: Compiles both midterm (`midterm_report.pdf`) and final (`final_report.pdf`) reports.
*   `make midterm`: Compiles the midterm report (`midterm_report.pdf`).
*   `make final`: Compiles the final report (`final_report.pdf`).
*   `make example`: Compiles the example document (`example.pdf`).
*   `make twice`: Compiles the midterm report twice to ensure cross-references are correct.
*   `make rebuild`: Cleans all generated files and then recompiles all reports.

## Code Style Guidelines
Adhere to consistent LaTeX formatting, clear document structure, and proper use of packages. Follow existing LaTeX conventions for document structure, command usage, and commenting.

## Commit Message Guidelines
All commit messages should follow the Conventional Commits specification. This helps in maintaining a clear and understandable version history.

The format is: `<type>: <description>`

**Common Types:**
*   `feat`: Adding new content, such as a chapter, section, or figure.
*   `fix`: Correcting typos, grammatical errors, or factual inaccuracies.
*   `style`: Changes to formatting, layout, or style files that don't change the content.
*   `refactor`: Restructuring `.tex` files or commands without changing the rendered output.
*   `docs`: Changes to documentation files (like this one).
*   `chore`: Other maintenance tasks, like updating build scripts or `.gitignore`.
