"""Generate the AnyCompany sample corpus used in the blog post.

Writes 8 business policies and 92 team pages to sample-data/corpus/.
Usage: python3 scripts/make_sample_corpus.py
"""
import pathlib

OUT = pathlib.Path(__file__).resolve().parent.parent / "sample-data" / "corpus"

POLICIES = {
    "finance/vendor-payment-policy.md": """# AnyCompany Vendor Payment Policy (FIN-004)
Owner: Finance Controller. Applies to all employees and contractors who initiate or approve vendor payments.

## Approval thresholds
- Payments up to USD 10,000 require one approver who is not the requester.
- Payments above USD 10,000 require two approvers, one of whom must be the Finance Controller.
- Payments above USD 50,000 additionally require approval from the Chief Financial Officer (CFO).
- No employee may approve a payment they requested.

## Changes to vendor bank details
- Requests to change a vendor's bank account details must never be actioned based on email alone.
- The Accounts Payable team must verify every bank detail change by calling the vendor on the phone number already on file in the vendor master record, not a number supplied in the request.
- A 48-hour hold applies to the first payment after any bank detail change.

## Urgent payment requests
Requests marked urgent, especially from executives, follow the same approval thresholds. Urgency is never a reason to bypass approvals.
""",
    "finance/travel-expense-policy.md": """# AnyCompany Travel and Expense Policy (FIN-011)
- Expense reports must be submitted within 30 days of the expense date.
- The daily meal allowance for domestic travel is USD 75 and for international travel is USD 110.
- Economy class is required for flights under 6 hours. Premium economy is allowed for flights of 6 hours or more.
- Receipts are required for any single expense above USD 25.
- Hotel bookings must be made through the corporate travel portal.
""",
    "customer/refund-policy.md": """# AnyCompany Customer Refund Policy (CS-002)
- Customers may request a full refund within 30 days of purchase with proof of purchase.
- Between 31 and 90 days, customers are eligible for store credit only.
- Refunds above USD 1,000 require approval from a Customer Service Team Lead.
- Refunds are issued to the original payment method only.
""",
    "security/password-and-mfa-standard.md": """# AnyCompany Password and MFA Standard (SEC-007)
- Passwords must be at least 14 characters long.
- Multi-factor authentication (MFA) is mandatory for all workforce accounts, including contractors.
- Phishing-resistant MFA (FIDO2 security keys) is required for administrators.
- Passwords must not be reused across the last 12 passwords.
- Never share one-time passcodes with anyone, including IT support.
""",
    "security/incident-escalation-runbook.md": """# AnyCompany Security Incident Escalation Runbook (SEC-019)
- Severity 1 incidents: page the security on-call engineer within 15 minutes of detection and notify the CISO within 1 hour.
- Severity 2 incidents: open a ticket and notify the security on-call engineer within 4 hours.
- Suspected payment fraud or business email compromise is always treated as Severity 1.
- Preserve evidence. Do not power off affected systems before the security team advises.
""",
    "legal/data-retention-policy.md": """# AnyCompany Data Retention Policy (LEG-003)
- Financial records are retained for 7 years.
- Customer personal data is deleted within 90 days after account closure, unless a legal hold applies.
- Application logs are retained for 13 months.
- Backups follow the same retention as the data they contain.
""",
    "hr/leave-policy.md": """# AnyCompany Leave Policy (HR-005)
- Full-time employees receive 25 days of paid annual leave per calendar year.
- Up to 5 unused days may be carried over to the next year and must be used by 31 March.
- Parental leave is 16 weeks fully paid for all parents.
""",
    "it/acceptable-use-policy.md": """# AnyCompany Acceptable Use Policy (IT-001)
- Company data may only be stored in approved systems: the corporate document store and approved SaaS applications.
- Customer data must never be pasted into unapproved generative AI tools.
- Personal devices may access email only when enrolled in mobile device management (MDM).
""",
}

TEAMS = ["platform", "payments", "data", "mobile", "web", "support", "sales-ops", "marketing",
         "logistics", "procurement", "analytics", "identity"]
TOPICS = ["onboarding-guide", "on-call-handbook", "meeting-cadence", "tooling-overview",
          "release-process", "faq", "glossary", "quarterly-goals"]
TOOLS = ["Jira", "Confluence", "GitLab", "Slack", "PagerDuty", "Grafana", "Figma", "Salesforce", "Tableau", "ServiceNow"]
USES = ["planning", "tracking work", "status updates", "design reviews", "reporting", "incident follow-up"]
TIMES = ["09:15", "09:30", "10:00"]
ITEMS = ["metrics", "open tickets", "customer feedback", "roadmap items"]
DAYS = ["Monday", "Wednesday", "Friday"]


def team_pages(limit):
    n = 0
    for team in TEAMS:
        for topic in TOPICS:
            if limit <= 0:
                return
            title = topic.replace("-", " ")
            lines = [f"# {team.title()} team: {title.title()}",
                     f"This page describes the {title} for the AnyCompany {team} team. "
                     f"It is maintained by the {team} team lead and reviewed every quarter."]
            for i in range(6):
                n += 1
                lines.append(f"- Item {i + 1}: The {team} team uses {TOOLS[(n * 7) % 10]} for {USES[(n * 5) % 6]}. "
                             f"Standups happen at {TIMES[n % 3]} and the team reviews {ITEMS[(n * 3) % 4]} "
                             f"every {DAYS[(n * 11) % 3]}.")
            lines.append(f"For questions, contact the {team} team channel.")
            limit -= 1
            yield f"teams/{team}/{topic}.md", "\n".join(lines) + "\n"


def main():
    docs = dict(POLICIES)
    docs.update(team_pages(100 - len(POLICIES)))
    for key, body in docs.items():
        path = OUT / key
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(body)
    print(f"Wrote {len(docs)} documents to {OUT}")


if __name__ == "__main__":
    main()
