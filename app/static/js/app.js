/* =============================================================================
   Enterprise Linux Health Dashboard — Client-side JavaScript
   ============================================================================= */

/**
 * Combined filter for search input, OS dropdown, and Status dropdown.
 */
function applyDashboardFilters() {
    const searchInput = document.getElementById('searchInput');
    const osFilter = document.getElementById('osFilter');
    const statusFilter = document.getElementById('statusFilter');

    const query = searchInput ? searchInput.value.toLowerCase().trim() : '';
    const selectedOS = osFilter ? osFilter.value.toLowerCase().trim() : 'all';
    const selectedStatus = statusFilter ? statusFilter.value.toLowerCase().trim() : 'all';

    const rows = document.querySelectorAll('.server-table-row');

    rows.forEach(function(row) {
        const hostname = row.getAttribute('data-hostname') || '';
        const os = row.getAttribute('data-os') || '';
        const ip = row.getAttribute('data-ip') || '';
        const kernel = row.getAttribute('data-kernel') || '';
        const status = row.getAttribute('data-status') || '';

        // Search match
        const matchesSearch = !query || 
            hostname.includes(query) || 
            os.includes(query) || 
            ip.includes(query) || 
            kernel.includes(query);

        // OS match
        const matchesOS = (selectedOS === 'all') || os.includes(selectedOS);

        // Status match
        let matchesStatus = (selectedStatus === 'all');
        if (!matchesStatus) {
            if (selectedStatus === 'healthy' && ['healthy', 'pass', 'completed'].includes(status)) {
                matchesStatus = true;
            } else if (selectedStatus === 'warning' && ['warning', 'warn'].includes(status)) {
                matchesStatus = true;
            } else if (selectedStatus === 'critical' && ['critical', 'fail', 'failed'].includes(status)) {
                matchesStatus = true;
            }
        }

        if (matchesSearch && matchesOS && matchesStatus) {
            row.style.display = '';
        } else {
            row.style.display = 'none';
        }
    });
}

/**
 * Filter dashboard by clicking stat cards.
 */
function filterByStatus(statusTarget) {
    const statusFilter = document.getElementById('statusFilter');
    if (statusFilter) {
        statusFilter.value = statusTarget;
        applyDashboardFilters();
    }
}

/**
 * Reset all dashboard filters.
 */
function resetFilters() {
    const searchInput = document.getElementById('searchInput');
    const osFilter = document.getElementById('osFilter');
    const statusFilter = document.getElementById('statusFilter');

    if (searchInput) searchInput.value = '';
    if (osFilter) osFilter.value = 'all';
    if (statusFilter) statusFilter.value = 'all';

    applyDashboardFilters();
}

/**
 * Auto-select the latest and second-latest reports in compare form.
 */
document.addEventListener('DOMContentLoaded', function() {
    const reportOld = document.getElementById('report_old');
    const reportNew = document.getElementById('report_new');

    if (reportOld && reportNew && !reportOld.value && !reportNew.value) {
        const options = reportNew.querySelectorAll('option[value]');
        if (options.length >= 2) {
            reportNew.value = options[0].value;
            reportOld.value = options[1].value;
        }
    }
});
