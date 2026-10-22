package com.winlator.root;

import android.util.Log;

import com.winlator.xenvironment.EnvironmentComponent;

/**
 * Mounts the chroot host paths before the X/audio/Vulkan sockets are created
 * and unmounts them after the guest launcher has stopped.
 */
public class ChrootComponent extends EnvironmentComponent {
    private final boolean fixSuid;
    private final boolean bindRam;
    private final boolean bindAndroid;

    public ChrootComponent(boolean fixSuid, boolean bindRam, boolean bindAndroid) {
        this.fixSuid = fixSuid;
        this.bindRam = bindRam;
        this.bindAndroid = bindAndroid;
    }

    public boolean isFixSuid() {
        return fixSuid;
    }

    public boolean isBindRam() {
        return bindRam;
    }

    public boolean isBindAndroid() {
        return bindAndroid;
    }

    @Override
    public void start() {
        Log.i("RootWinlator", "ChrootComponent.start ready="+RootBootstrap.isReady()+
            " supported="+RootBootstrap.isChrootSupported()+" flags="+fixSuid+","+bindRam+","+bindAndroid);
        if (RootBootstrap.isReady() && RootBootstrap.isChrootSupported()) {
            boolean ok = ChrootManager.mount(environment.getContext(), fixSuid, bindRam, bindAndroid);
            Log.i("RootWinlator", "ChrootComponent.start mount="+ok);
        }
    }

    @Override
    public void stop() {
        Log.i("RootWinlator", "ChrootComponent.stop");
        if (RootBootstrap.isReady() && RootBootstrap.isChrootSupported()) {
            ChrootManager.stop(environment.getContext());
        }
    }
}
