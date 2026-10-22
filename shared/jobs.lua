-- grades are 0-indexed. boss = can manage the job (for your own boss menus)
Config.Jobs = {
    unemployed = {
        label = 'Unemployed',
        grades = {
            [0] = { label = 'Unemployed', salary = 50 },
        },
    },
    police = {
        label = 'LSPD',
        grades = {
            [0] = { label = 'Cadet', salary = 150 },
            [1] = { label = 'Officer', salary = 250 },
            [2] = { label = 'Sergeant', salary = 350 },
            [3] = { label = 'Chief', salary = 500, boss = true },
        },
    },
    ambulance = {
        label = 'EMS',
        grades = {
            [0] = { label = 'Trainee', salary = 150 },
            [1] = { label = 'Paramedic', salary = 250 },
            [2] = { label = 'Chief', salary = 450, boss = true },
        },
    },
}
