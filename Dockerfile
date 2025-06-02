FROM ironmansoftware/universal:latest

# Copy PowerShell Universal Dashboard files
COPY ./Dashboard.ps1 /app/universal/dashboard.ps1
COPY ./estate_planning.ps1 /app/scripts/Run-SqlInventory.ps1

# Set the dashboard to load automatically
ENV POWERSHELL_DASHBOARD_FILE=/app/universal/dashboard.ps1

# Expose the dashboard port
EXPOSE 5000
