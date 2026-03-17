#!/bin/sh
# Example quota probe - returns mock data
# Replace this with real API calls or CLI commands

cat <<'EOF'
{
    "quotas": [
        {
            "type": "session",
            "percentRemaining": 85.0,
            "resetsAt": "2026-03-17T23:00:00Z"
        },
        {
            "type": "weekly",
            "percentRemaining": 62.0,
            "resetsAt": "2026-03-21T00:00:00Z"
        }
    ],
    "account": {
        "email": "user@example.com",
        "tier": "Pro"
    }
}
EOF
