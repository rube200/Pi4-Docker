const SERVICES = [
    { path: 'home-assistant', btnId: 'homeAssistantBtn', imgId: 'redirectToHomeAssistant' },
    { path: 'kodi', btnId: 'kodiBtn', imgId: 'redirectToKodi' },
    { path: 'pi-hole', btnId: 'piHoleBtn', imgId: 'redirectToPiHole' }
];

const CHECK_INTERVAL = 10000;
const CHECK_TIMEOUT = 3000;

function getSubdomainUrl(subdomain) {
    const url = new URL('/', window.location.origin);
    url.hostname = `${subdomain}.${url.hostname}`;
    return url.href;
}

function setEnabled(btn, img, enabled) {
    btn.classList.toggle('disabled', !enabled);
    img.style.opacity = enabled ? '1' : '0.5';
    img.style.cursor = enabled ? 'pointer' : 'not-allowed';
}

async function checkService(service, btn, img) {
    const controller = new AbortController();
    const timeoutId = setTimeout(() => controller.abort(), CHECK_TIMEOUT);

    try {
        const response = await fetch(getSubdomainUrl(service.path), {
            method: 'HEAD',
            cache: 'no-cache',
            mode: 'cors',
            redirect: 'manual',
            signal: controller.signal
        });
        setEnabled(btn, img, response.ok);
    } catch (error) {
        if (!btn.classList.contains('disabled')) {
            console.warn(`${service.path} is unreachable: ${error.message}`);
        }
        setEnabled(btn, img, false);
    } finally {
        clearTimeout(timeoutId);
    }
}

document.addEventListener('DOMContentLoaded', () => {
    document.title = `${window.location.hostname} - Landing Page`;

    const wired = [];
    for (const service of SERVICES) {
        const btn = document.getElementById(service.btnId);
        const img = document.getElementById(service.imgId);
        if (!btn || !img) {
            continue;
        }

        const navigate = (event) => {
            event.preventDefault();
            if (!btn.classList.contains('disabled')) {
                window.location.href = getSubdomainUrl(service.path);
            }
        };
        btn.addEventListener('click', navigate);
        img.addEventListener('click', navigate);

        wired.push({ service, btn, img });
    }

    const checkAll = () => wired.forEach(({ service, btn, img }) => checkService(service, btn, img));
    checkAll();
    setInterval(checkAll, CHECK_INTERVAL);
});
