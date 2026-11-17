// Build-time dictionary deployment keeps compiler memory out of the keyboard process.
#include "rime_api.h"
int main(int argc, char **argv) {
    if (argc != 3) return 2;
    RimeTraits traits = {0};
    traits.data_size = sizeof(traits) - sizeof(traits.data_size);
    traits.shared_data_dir = argv[1];
    traits.user_data_dir = argv[2];
    traits.app_name = "rime.vvhisper";
    traits.min_log_level = 3;
    RimeApi *api = rime_get_api();
    api->setup(&traits);
    api->initialize(&traits);
    if (api->start_maintenance(true)) api->join_maintenance_thread();
    RimeSessionId session = api->create_session();
    bool ok = session && api->select_schema(session, "vvhisper_pinyin");
    api->finalize();
    return ok ? 0 : 1;
}
