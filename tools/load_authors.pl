#!/usr/bin/env perl

use warnings;
use strict;

# Потрібно для налагодження
use utf8;
binmode STDOUT, ":utf8";
use Data::Dumper;

use 5.010;

use JSON -convert_blessed_universally;
use Getopt::Long;
use Pod::Usage;
use WWW::Curl::Easy;
use URI::Escape;
use Hash::Merge::Simple qw/merge/;

=encoding utf8

=head1 NAME

load_authors.pl — команда завантажує або оновлює інформацію про авторів з wikipedia.org

=head1 SYNOPSIS

    ./load_authors.pl \
        --from old.json --to new.json \
        --lang uk --langs=ru,en,crh \
        --category 'Категорія:Українські поети'

=head1 DESCRIPTION

Ця команда для завантаження або оновлення інформації про авторів. Зберігає
у форматі C<api-authors.json> наступні поля:

    [
       {
          "name" : {
             "uk" : "Руданський Степан Васильович",
             "ru" : "Руданский, Степан Васильевич"
          },                
          "wiki" : {        
             "uk" : "https://uk.wikipedia.org/wiki/Руданський Степан Васильович",
             "ru" : "https://ru.wikipedia.org/wiki/Руданский, Степан Васильевич"
          },                
          "tags" : [        
             {              
                "uk" : "Українські поети",
                "en" : "Ukrainian poets",
                "ru" : "Поэты Украины"
             }
          ]
       }
    ]

=head2 Options

=over 4

=item --from

Файл у форматі JSON, з якого беруться дані для доповнення.

=item --to

Файл у форматі JSON, в який будуть збережені результати.
Обов'язкова опція.

=item --lang

Мова для запиту до https://www.mediawiki.org/wiki/API:Main_page
Вона же використовується для локалізації даних.
Обов'язкова опція.

=item --langs

Мови за якими завантажуються дані у інших локалізаціях.

=item --category

Вказується повна назва категорії з wikipedia.org для завантаження списку авторів.
Обов'язкова опція.

=back

=cut

my $url_template_categoryinfo = 'https://{lang}.wikipedia.org/w/api.php?action=query&prop=categoryinfo&format=json&titles={titles}';
my $url_template_categorymembers = 'https://{lang}.wikipedia.org/w/api.php?action=query&format=json&list=categorymembers&cmpageid={cmpageid}&cmtype=page&cmlimit=25';
my $url_template_langlinks = 'https://{lang}.wikipedia.org/w/api.php?action=parse&format=json&pageid={pageid}&prop=langlinks';
my $url_template_info_url = 'https://{lang}.wikipedia.org/w/api.php?action=query&prop=info&format=json&inprop=url&pageids={pageids}';

my $curl;

my @langs;
my $to_file;
my $lang;
my $category_title;

my $authors = [];
my $authors_index;

GetOptions(
    'from=s'        => \&load_json,
    'to=s'          => \$to_file,
    'lang=s'        => \$lang,
    'category=s'    => \$category_title,
    'langs=s'       => \@langs,
    'help|?'        => sub { pod2usage(0) }
);

# Нормалізуємо список мов
@langs = split(/,/,join(',',@langs));
unshift(@langs, $lang)
    unless ($lang ~~ @langs);

if (defined $lang && defined $category_title && defined $to_file) {

    init_curl();

    update_authors($authors, {
        lang => $lang,
        titles => $category_title});

    open DATA, ">".$to_file || die $!;
    print DATA JSON->new->allow_blessed->convert_blessed->utf8->pretty->encode($authors);
    close DATA;

} else {
    pod2usage(-message => "Something wrong.",
              -exitval => 2,
              -verbose => 0,
              -output  => \*STDERR);
}

sub load_json {
    shift;
    my ($file) = @_;

    open(DATA, $file) || die "Can't open JSON file '$file': $!";
    $authors = JSON->new->utf8->decode(join '', <DATA>);
    close(DATA);

    # Будуємо індекс
    my $i = 0;
    foreach my $member (@{$authors}) {
        foreach my $lang (keys %{$member->{name}}) {
            $authors_index->{$lang}->{$member->{name}->{$lang}} = $i;
        }
        ++$i;
    }
}

sub update_authors {
    my ($authors, $params) = @_;

    my $data = get_curl_data($url_template_categoryinfo, $params);
    check_wiki_data($data, 'query');

    my @pageids = keys %{$data->{query}->{pages}};

    if ($pageids[0] == -1) {
        warn "Wiki: Category '".$params->{titles}."' not found\n";
        warn "Exit with code -1";
        exit -1;
    }

    my $members = get_categorymembers({
        lang     => $params->{lang},
        cmpageid => $data->{query}->{pages}->{$pageids[0]}->{pageid}});

    # Запитуємо список перекладів назви категорії
    my $tags = get_page_langs({
        lang   => $params->{lang},
        pageid => $data->{query}->{pages}->{$pageids[0]}->{pageid}});
    $tags->{name}->{$params->{lang}} = $data->{query}->{pages}->{$pageids[0]}->{title};
    foreach my $lang (keys %{$tags->{name}}) {
        $tags->{name}->{$lang} =~ s/^.*\:(.*)$/$1/;
    }

    foreach my $member (keys %{$members}) {

        # Шукаємо в $authors[] по імені, по всіх відомих мовах
        my $author_idx;
        foreach my $lang (keys %{$members->{$member}->{name}}) {
            if (exists $authors_index->{$lang}->{$members->{$member}->{name}->{$lang}}) {
                $author_idx = $authors_index->{$lang}->{$members->{$member}->{name}->{$lang}};
                last;
            }
        }
        if (defined $author_idx) {
            # Якщо знайшли, то додаємо всі поля, яких немає в $authors[]

            my $merged = merge($members->{$member}, $authors->[$author_idx]);

            # Перевіряємо і додаємо категорію за необхідності,
            # бо вона не додається методом Hash::Merge::Simple->merge()
            my $is_tagged = 0;
            foreach my $tag (@{$merged->{tags}}) {
                if ($tag->{$params->{lang}} eq $tags->{name}->{$params->{lang}}) {
                    $is_tagged++;
                    last;
                }
            }
            push(@{$merged->{tags}}, $tags->{name})
                unless $is_tagged;

            $authors->[$author_idx] = $merged;
        } else {
            # Якщо не знайшли, то додаємо в $authors

            # Додаємо категорію, за якою шукали у теги
            push(@{$members->{$member}->{tags}}, $tags->{name});

            push(@{$authors}, $members->{$member});
        }
    }
}

sub get_categorymembers {
    my ($params) = @_;
    my $members = {};
    my $data;

    do {
        $params->{cmcontinue} = $data->{continue}->{cmcontinue}
            if exists $data->{continue};
        $data = get_curl_data(
            $url_template_categorymembers,
            $params);

        my @pageids = map { $_->{pageid} } @{$data->{query}->{categorymembers}};

        # Запитуємо список імен і посилання на wiki для даної мови
        get_author_info($members, {
                lang    => $params->{lang},
                pageids => join('|', @pageids)});

        # Запитуємо список імен і посилання на wiki для інших мов
        foreach my $pageid (@pageids) {
            my $result = get_page_langs({
                    lang   => $params->{lang},
                    pageid => $pageid});
            if (exists $result->{name}) {
                foreach my $lang (keys %{$result->{name}}) {
                    $members->{$pageid}->{name}->{$lang} = $result->{name}->{$lang};
                    $members->{$pageid}->{wiki}->{$lang} = $result->{wiki}->{$lang};
                }
            }
        }

    } until (!exists $data->{continue});

    return $members;
}

sub get_author_info {
    my ($result, $params) = @_;

    my $data = get_curl_data(
            $url_template_info_url,
            $params
        );
    check_wiki_data($data, 'query');

    foreach my $pageid (keys %{$data->{query}->{pages}}) {
        $result->{$pageid}->{name}->{$params->{lang}} = $data->{query}->{pages}->{$pageid}->{title};
        $result->{$pageid}->{wiki}->{$params->{lang}} = $data->{query}->{pages}->{$pageid}->{fullurl};
    }
}

sub get_page_langs {
    my ($params) = @_;
    my $result;

    my $data = get_curl_data(
            $url_template_langlinks,
            $params);

    foreach my $langlink (@{$data->{parse}->{langlinks}}) {
        foreach my $l (@langs) {
            if ($langlink->{lang} eq $l) {
                $result->{name}->{$l} = unescape($langlink->{'*'});
                $result->{wiki}->{$l} = $langlink->{url};
                last;
            }
        }
    }

    return $result;
}

sub init_curl {
    $curl = new WWW::Curl::Easy->new;
    $curl->setopt(CURLOPT_FOLLOWLOCATION, 1);
    $curl->setopt(CURLOPT_COOKIEFILE, '');
    $curl->setopt(CURLOPT_COOKIEJAR, '');
    $curl->setopt(CURLOPT_USERAGENT, 'sharedBooks/0.0.1 (http://SB.TLD/; levonet@gmail.com)');
}

sub get_curl_data {
    my ($url_template, $params) = @_;
    my $url = $url_template;

    foreach my $key (keys %{$params}) {
        my $value = uri_escape($params->{$key});
        if ($url =~ m/\{$key\}/) {
            $url =~ s/^(.*)\{$key\}(.*)$/$1$value$2/;
        } else {
            $url .= '&'.$key.'='.$value;
        }
    }

    my $datajson;
    $curl->setopt(CURLOPT_URL, $url);
    $curl->setopt(CURLOPT_WRITEDATA, \$datajson);
    my $retcode = $curl->perform;
    my $httpcode = $curl->getinfo(CURLINFO_HTTP_CODE);

    if ($retcode) {
        warn "cURL Error: ".$curl->strerror($retcode).". ".$curl->errbuf."\n";
        warn "Exit with code ".$retcode;
        exit $retcode;
    }

    my $data = JSON->new->utf8->decode($datajson);
    check_wiki_error($data);

    return $data;
}

sub check_wiki_error {
    my ($data) = @_;

    if (exists $data->{error}) {
        warn "Wiki Error: ".$data->{error}->{code}.". ".$data->{error}->{info}."\n";
        warn "Exit with code -1";
        exit -1;
    }
}

sub check_wiki_data {
    my ($data, $test) = @_;

    if (!exists $data->{$test} && exists $data->{warnings}) {
        warn "Wiki Warnings: ".$data->{warnings}->{main}->{'*'}."\n";
        warn "Exit with code -1";
        exit -1;
    }
}

sub unescape {
    my $src = shift;
    $src =~ s/\\x\{(.{2})\}/chr hex $1/eg;
    return $src;
}

1;

=head1 AUTHOR

Pavlo Bashyński E<lt>levonet {at} gmail {dot} comE<gt>

=head1 LICENSE

This is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
