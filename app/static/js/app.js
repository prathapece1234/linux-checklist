/* =============================================================================
   Enterprise Linux Health Dashboard — Client-side JavaScript
   ============================================================================= */

/**
 * Filter dashboard server cards by search input.
 */
function filterCards() {
    const query = document.getElementById('searchInput').value.toLowerCase().trim();
    const cards = document.querySelectorAll('.server-card');

    cards.forEach(function(card) {
        const searchData = card.getAttribute('data-search') || '';
        if (!query || searchData.includes(query)) {
            card.style.display = '';
        } else {
            card.style.display = 'none';
        }
    });
}

/**
 * Auto-select the latest and second-latest reports in the compare form.
 */
document.addEventListener('DOMContentLoaded', function() {
    const reportOld = document.getElementById('report_old');
    const reportNew = document.getElementById('report_new');

    if (reportOld && reportNew && !reportOld.value && !reportNew.value) {
        const options = reportNew.querySelectorAll('option[value]');
        if (options.length >= 2) {
            // Newest = options[0], Second newest = options[1]
            reportNew.value = options[0].value;
            reportOld.value = options[1].value;
        }
    }
});
