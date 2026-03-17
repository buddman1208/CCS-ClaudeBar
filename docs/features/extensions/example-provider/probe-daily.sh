#!/bin/sh
# Example daily usage probe - returns today vs previous day comparison
# Replace with real data (parse logs, query APIs, etc.)

# Get today's and yesterday's dates for realistic output
TODAY=$(date +%Y-%m-%d)
YESTERDAY=$(date -v-1d +%Y-%m-%d)
YESTERDAY_LABEL=$(date -v-1d +"%b %d")

cat <<EOF
{
    "dailyUsage": {
        "today": {
            "totalCost": 10.26,
            "totalTokens": 8300000,
            "workingTime": 454.0,
            "date": "$TODAY",
            "sessionCount": 12
        },
        "previous": {
            "totalCost": 711.84,
            "totalTokens": 8693000,
            "workingTime": 42514.0,
            "date": "$YESTERDAY",
            "sessionCount": 45
        }
    }
}
EOF
