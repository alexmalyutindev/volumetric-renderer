using UnityEngine;
using UnityEditor;
using System.Collections.Generic;

public class PrefabNameRevert
{
    [MenuItem("Custom/Revert Name")]
	static void RevertPrefabNames()
    {
        RevertAllNames(Selection.GetFiltered(typeof(GameObject), SelectionMode.Editable));
	}

    public static void RemoveNameModification(UnityEngine.Object aObj)
    {
        for (int j = 0; j < 10 && PrefabUtility.IsPartOfPrefabThatCanBeAppliedTo(aObj); j++)
        {
            var originalMods = PrefabUtility.GetPropertyModifications(aObj);
            if (originalMods == null) continue;
            
            var mods = new List<PropertyModification>(originalMods);
            for (int i = 0; i < mods.Count; i++)
            {
                if (mods[i].propertyPath == "m_Name")
                    mods.RemoveAt(i);
            }

            PrefabUtility.SetPropertyModifications(aObj, mods.ToArray());
            aObj = PrefabUtility.GetCorrespondingObjectFromOriginalSource(aObj);
        }
    }
    public static void RevertAllNames(Object[] aObjects)
    {
        var items = new List<Object>();
        for (var index = 0; index < aObjects.Length; index++)
        {
            var item = aObjects[index];
            
            var prefab = PrefabUtility.GetCorrespondingObjectFromOriginalSource(item);
            for (int i = 0; i < 10 && PrefabUtility.IsPartOfPrefabThatCanBeAppliedTo(prefab); i++)
            {
                prefab = PrefabUtility.GetCorrespondingObjectFromOriginalSource(item);
            }

            if (prefab != null)
            {
                Undo.RecordObject(item, "Revert perfab name");
                for (int i = 0; i < 10 && PrefabUtility.IsPartOfPrefabThatCanBeAppliedTo(item); i++)
                {
                    item.name = prefab.name;
                    item = PrefabUtility.GetCorrespondingObjectFromOriginalSource(item);
                }

                items.Add(item);
            }
        }

        Undo.FlushUndoRecordObjects();
        foreach (var item in items)
        {
            RemoveNameModification(item);
        }
    }
}