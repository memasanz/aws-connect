"""Generate fake test documents in a nested hierarchy for the aws-connect E2E test."""
import os, shutil, zipfile
from reportlab.lib.pagesizes import letter
from reportlab.lib.units import inch
from reportlab.pdfgen import canvas
from docx import Document

STAGE = os.environ.get("STAGE", os.path.join(os.environ["TEMP"], "aws-connect-testdocs"))

LOREM = (
    "The quarterly results reflect steady growth across all business units. "
    "Revenue increased compared to the prior period driven by strong demand. "
    "Operating margins improved as the team executed on cost discipline. "
    "Management remains optimistic about the outlook for the coming year. "
)

def multipage_pdf(path, title, pages):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    c = canvas.Canvas(path, pagesize=letter)
    w, h = letter
    for p in range(1, pages + 1):
        c.setFont("Helvetica-Bold", 16)
        c.drawString(1 * inch, h - 1 * inch, f"{title} — Page {p} of {pages}")
        c.setFont("Helvetica", 11)
        y = h - 1.5 * inch
        # ~24 lines of text so each page has real, extractable content
        for line in range(24):
            c.drawString(1 * inch, y, f"[p{p} L{line+1}] " + LOREM[: 90])
            y -= 0.28 * inch
        c.showPage()
    c.save()
    print("PDF ", path, f"({pages}p)")

def make_docx(path, title, paras):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    d = Document()
    d.add_heading(title, 0)
    for i in range(paras):
        d.add_paragraph(f"Section {i+1}. " + LOREM * 2)
    d.save(path)
    print("DOCX", path)

def make_txt(path, title, lines):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        f.write(title + "\n\n")
        for i in range(lines):
            f.write(f"{i+1}. " + LOREM + "\n")
    print("TXT ", path)

def make_zip_unsupported(path):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with zipfile.ZipFile(path, "w") as z:
        z.writestr("readme.txt", "unsupported archive to exercise the skip path")
    print("ZIP ", path, "(unsupported)")

def main():
    if os.path.exists(STAGE):
        shutil.rmtree(STAGE)
    os.makedirs(STAGE)
    j = lambda *p: os.path.join(STAGE, *p)

    # finance/ (has ACL)
    multipage_pdf(j("finance", "reports", "2024", "q1", "q1-earnings.pdf"), "Q1 2024 Earnings", 5)
    multipage_pdf(j("finance", "reports", "2024", "q2", "q2-earnings.pdf"), "Q2 2024 Earnings", 3)
    make_txt(j("finance", "reports", "2024", "q1", "analyst-notes.txt"), "Analyst Notes Q1", 12)
    make_docx(j("finance", "policies", "expense-policy.docx"), "Expense Reimbursement Policy", 6)

    # hr/ (has ACL)
    multipage_pdf(j("hr", "handbook", "employee-handbook.pdf"), "Employee Handbook", 8)
    multipage_pdf(j("hr", "onboarding", "welcome-guide.pdf"), "New Hire Welcome Guide", 2)
    make_zip_unsupported(j("hr", "handbook", "handbook-archive.zip"))  # unsupported -> skip

    # engineering/ (NO ACL entry -> no_acl skip unless bypass), deeply nested
    multipage_pdf(j("engineering", "specs", "platform", "v2", "internal", "draft",
                    "architecture-spec.pdf"), "Platform Architecture Spec", 4)

    print("\nSTAGE:", STAGE)
    total = sum(len(fs) for _, _, fs in os.walk(STAGE))
    print("total files:", total)

if __name__ == "__main__":
    main()
