package com.winlator.root;

import android.content.Context;
import android.view.View;
import android.widget.CheckBox;
import com.winlator.R;
import com.winlator.container.Container;
import com.winlator.core.AppUtils;
import com.winlator.xenvironment.RootFS;
import org.json.JSONException;
import org.json.JSONObject;

/**
 * Helper class to encapsulate chroot UI bindings in Container settings,
 * minimizing intrusive modifications to ContainerDetailFragment.
 */
public abstract class ChrootUIHelper {
    public static void initViews(View view, Container container, boolean isEditMode) {
        CheckBox cbRam = view.findViewById(R.id.CBCBindRam);
        CheckBox cbAndroid = view.findViewById(R.id.CBCBindAndroid);
        if (cbRam != null) cbRam.setChecked(!isEditMode || (container != null && !container.getExtra("chrootBindRam", "1").equals("0")));
        if (cbAndroid != null) cbAndroid.setChecked(!isEditMode || (container != null && !container.getExtra("chrootBindAndroid", "1").equals("0")));
    }

    public static boolean checkRootFSReady(Context context, boolean isEditMode) {
        if (!isEditMode && !RootFS.find(context).isValid()) {
            AppUtils.showToast(context, R.string.rootfs_not_ready);
            return false;
        }
        return true;
    }

    public static void saveContainerData(View view, Container container) {
        CheckBox cbRam = view.findViewById(R.id.CBCBindRam);
        CheckBox cbAndroid = view.findViewById(R.id.CBCBindAndroid);
        if (cbRam != null && container != null) container.putExtra("chrootBindRam", cbRam.isChecked() ? "1" : "0");
        if (cbAndroid != null && container != null) container.putExtra("chrootBindAndroid", cbAndroid.isChecked() ? "1" : "0");
    }

    public static void saveCreationData(View view, JSONObject data) {
        CheckBox cbRam = view.findViewById(R.id.CBCBindRam);
        CheckBox cbAndroid = view.findViewById(R.id.CBCBindAndroid);
        if (cbRam != null && cbAndroid != null && data != null) {
            try {
                JSONObject chrootData = new JSONObject();
                chrootData.put("chrootBindRam", cbRam.isChecked() ? "1" : "0");
                chrootData.put("chrootBindAndroid", cbAndroid.isChecked() ? "1" : "0");
                data.put("extraData", chrootData);
            }
            catch (JSONException ignored) {}
        }
    }
}
