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
			const url = getSubdomainUrl(service.path);
			const response = await fetch(url, {
				method: 'HEAD',
				cache: 'no-cache',
				mode: 'cors',
				redirect: 'manual',
				signal: controller.signal,
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

function setPageTitle() {
	const hostname = window.location.hostname;
	const parts = hostname.split('.');
	let baseDomain;
	if (parts.length >= 2) {
		baseDomain = parts.slice(-2).join('.');
	} else {
		baseDomain = hostname;
	}
	document.title = `${baseDomain} - Landing Page`;
}

document.addEventListener('DOMContentLoaded', () => {
	setPageTitle();

	new ServiceChecker();

	const homeAssistantImg = document.getElementById("redirectToHomeAssistant");
	const homeAssistantBtn = document.getElementById("homeAssistantBtn");
	redirectOnClick(homeAssistantImg, "home-assistant");
	redirectOnClick(homeAssistantBtn, "home-assistant");

	const kodiImg = document.getElementById("redirectToKodi");
	const kodiBtn = document.getElementById("kodiBtn");
	redirectOnClick(kodiImg, "kodi");
	redirectOnClick(kodiBtn, "kodi");

	const piHoleImg = document.getElementById("redirectToPiHole");
	const piHoleBtn = document.getElementById("piHoleBtn");
	redirectOnClick(piHoleImg, "pi-hole");
	redirectOnClick(piHoleBtn, "pi-hole");
});

function getSubdomainUrl(subDomain) {
	const hostname = window.location.hostname;
	const parts = hostname.split('.');
	
	let baseDomain;
	if (parts.length >= 2) {
		baseDomain = parts.slice(-2).join('.');
	} else {
		baseDomain = hostname;
	}
	
	const targetHostname = `${subDomain}.${baseDomain}`;
	if (hostname === targetHostname) {
		return window.location.href;
	}
	
	return window.location.href.replace(hostname, targetHostname);
}

function redirectOnClick(element, subDomain) {
	if (!(element instanceof HTMLElement) || typeof subDomain !== 'string') {
		return;
	}

	const url = getSubdomainUrl(subDomain);
	element.addEventListener("click", (e) => {
		const targetElement = element.id?.startsWith('redirectTo')
			? document.getElementById(element.id.replace('redirectTo', '').replace(/^./, c => c.toLowerCase()) + 'Btn')
			: element;
		
		if (targetElement?.classList.contains('disabled')) {
			e.preventDefault();
			e.stopPropagation();
			return;
		}
		
		window.location.href = url;
	});
}
