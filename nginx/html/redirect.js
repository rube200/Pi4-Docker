class ServiceChecker {
	constructor() {
		this.services = [
			{ name: 'homeAssistant', path: 'home-assistant', btnId: 'homeAssistantBtn', imgId: 'redirectToHomeAssistant' },
			{ name: 'kodi', path: 'kodi', btnId: 'kodiBtn', imgId: 'redirectToKodi' },
			{ name: 'piHole', path: 'pi-hole', btnId: 'piHoleBtn', imgId: 'redirectToPiHole' }
		];
		this.checkInterval = 10000;
		this.timeout = 3000;
		this.init();
	}

	init() {
		this.services.forEach(service => {
			this.checkService(service);
		});

		setInterval(() => {
			this.services.forEach(service => {
				this.checkService(service);
			});
		}, this.checkInterval);
	}

	async checkService(service) {
		const btn = document.getElementById(service.btnId);
		const img = document.getElementById(service.imgId);
		if (!btn || !img) {
			return;
		}

		const controller = new AbortController();
		const timeoutId = setTimeout(() => controller.abort(), this.timeout);

		try {
			const url = getSubdomainUrl(subDomain)
			const response = await fetch(url, {
				method: 'HEAD',
				signal: controller.signal,
				cache: 'no-cache'
			});

			clearTimeout(timeoutId);
			if (response.ok) {
				this.enableService(btn, img);
			} else {
				this.disableService(btn, img);
			}
		} catch (error) {
			clearTimeout(timeoutId);
			this.disableService(btn, img);
		}
	}

	disableService(btn, img) {
		btn.classList.add('disabled');
		img.style.opacity = '0.5';
		img.style.cursor = 'not-allowed';
	}

	enableService(btn, img) {
		btn.classList.remove('disabled');
		img.style.opacity = '1';
		img.style.cursor = 'pointer';
	}
}

document.addEventListener('DOMContentLoaded', () => {
	new ServiceChecker();

	const homeAssistantImg = document.getElementById("redirectToHomeAssistant");
	redirectOnClick(homeAssistantImg, "home-assistant");

	const kodiImg = document.getElementById("redirectToKodi");
	redirectOnClick(kodiImg, "kodi");

	const piHoleImg = document.getElementById("redirectToPiHole");
	redirectOnClick(piHoleImg, "pi-hole");
});

function getSubdomainUrl(subDomain) {
	const domain = window.location.hostname;
	return window.location.href.replace(window.location.hostname, `${subDomain}.${domain}`);
}


function redirectOnClick(element, subDomain) {
	if (!(element instanceof HTMLElement)) {
		return true;
	}

	if (typeof subDomain !== 'string' && !(subDomain instanceof String)) {
		return false;
	}

	const url = getSubdomainUrl(subDomain)
	element.addEventListener("click", () => window.location.href=url);
	return true;
}
