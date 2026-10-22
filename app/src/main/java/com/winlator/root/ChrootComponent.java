package com.winlator.root;

import android.util.Log;

import com.winlator.xenvironment.EnvironmentComponent;

/**
 * Mounts the chroot host paths before the X/audio/Vulkan sockets are created
 * and unmounts them after the guest launcher has stopped.
 */
public class ChrootComponent extends EnvironmentComponent {
    private final boolean bindRam;
    private final boolean bindAndroid;

    public ChrootComponent(boolean bindRam, boolean bindAndroid) {
        this.bindRam = bindRam;
        this.bindAndroid = bindAndroid;
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
            " supported="+RootBootstrap.isChrootSupported()+" flags="+bindRam+","+bindAndroid);
        if (RootBootstrap.isReady() && RootBootstrap.isChrootSupported()) {
            boolean ok = ChrootManager.mount(environment.getContext(), bindRam, bindAndroid);
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
