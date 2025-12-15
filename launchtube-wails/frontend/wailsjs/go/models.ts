export namespace main {
	
	export class AppConfig {
	    name: string;
	    url?: string;
	    matchUrls?: string[];
	    commandLine?: string;
	    type: number;
	    imagePath?: string;
	    colorValue: number;
	    showName: boolean;
	    serviceId?: string;
	
	    static createFrom(source: any = {}) {
	        return new AppConfig(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.name = source["name"];
	        this.url = source["url"];
	        this.matchUrls = source["matchUrls"];
	        this.commandLine = source["commandLine"];
	        this.type = source["type"];
	        this.imagePath = source["imagePath"];
	        this.colorValue = source["colorValue"];
	        this.showName = source["showName"];
	        this.serviceId = source["serviceId"];
	    }
	}
	export class BrowserInfo {
	    name: string;
	    executable: string;
	    fullscreenFlag: string;
	
	    static createFrom(source: any = {}) {
	        return new BrowserInfo(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.name = source["name"];
	        this.executable = source["executable"];
	        this.fullscreenFlag = source["fullscreenFlag"];
	    }
	}
	export class Profile {
	    id: string;
	    displayName: string;
	    colorValue: number;
	    photoPath?: string;
	    order: number;
	
	    static createFrom(source: any = {}) {
	        return new Profile(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.id = source["id"];
	        this.displayName = source["displayName"];
	        this.colorValue = source["colorValue"];
	        this.photoPath = source["photoPath"];
	        this.order = source["order"];
	    }
	}
	export class ServiceTemplate {
	    name: string;
	    url: string;
	    matchUrls?: string[];
	    colorValue: number;
	    logoPath?: string;
	
	    static createFrom(source: any = {}) {
	        return new ServiceTemplate(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.name = source["name"];
	        this.url = source["url"];
	        this.matchUrls = source["matchUrls"];
	        this.colorValue = source["colorValue"];
	        this.logoPath = source["logoPath"];
	    }
	}

}

