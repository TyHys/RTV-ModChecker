from mod_checker.utils import analysis_folder_name, sanitize_name


def test_sanitize_name():
    assert sanitize_name(" My Mod / Name ") == "My-Mod-Name"
    assert sanitize_name("???") == "unknown-mod-name"


def test_analysis_folder_name():
    folder = analysis_folder_name("56156", "Kill Counter", "v1.2.3")
    assert folder == "56156-Kill-Counter-v1.2.3"

